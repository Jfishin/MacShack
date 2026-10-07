// File-backed memory tier ("userspace swap"), after Madeira's ml1077 (Wine's VirtualAlloc), here at mmap.
//
// iOS has no anonymous swap: jetsam kills an app when phys_footprint reaches its limit (8 GB on this phone). Dirty pages
// of a MAP_SHARED file mapping are different: they are file cache, not charged to phys_footprint, stay in RAM while
// there is room, and are written to the file and evicted only under memory pressure (Madeira measured on device:
// 512 MB written -> footprint +2 MB; God of War's footprint 8109 -> 4253 MB with 1.6 GB backed).
//
// Unreal maps most of its heap in small pieces (Lies of P: ~3 GB live in mmaps averaging 200 KB, 10 GB of churn a
// minute), so instead of a mapping per allocation there is one arena: the whole backing file mapped once, page i of the
// arena = page i of the file. A guest mmap takes a free run from a page bitmap; munmap punches the file range (freeing
// its memory and disk, so it reads as zero again) and remaps it read-write, keeping the address reserved for reuse.
// A MAP_FIXED remap inside the arena (an allocator committing or decommitting its own pages) is done the same way.
//
// Not backed: executable or JIT requests, file mappings, calls from the dyld shared cache (system frameworks).
// ponytail: madvise(MADV_FREE/DONTNEED) on arena pages frees nothing (a shared mapping keeps its data); those pages are
// not charged to the footprint anyway. Hook madvise to punch them if disk use matters.
// ponytail: large malloc() blocks come from libmalloc's mach_vm_map, which fishhook cannot reach; engines with their own
// allocator (Unreal, The Forge) call mmap and are covered.
#include "ShackSwap.h"
#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <unistd.h>

extern const void *_dyld_get_shared_cache_range(size_t *length);   // libdyld export (dyld_priv.h)

static int gFd = -1;
static char *gBase;
static size_t gPage, gPages, gCursor;   // gCursor: next-fit start
static uint64_t *gMap;                  // one bit per arena page, 1 = handed to the guest
static uint64_t gUsed, gPeak, gRefused, gForeign;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static uintptr_t gCacheLo, gCacheHi;
static ShackMmapFn gMmap;
#ifdef SHACK_SWAP_TEST
static int gPunchError;
void ShackSwapTestFailPunch(int error) { gPunchError = error; }
#endif

int ShackSwapInit(const char *path, uint64_t capMB, ShackMmapFn realMmap) {
    if (!realMmap) { errno = EINVAL; return -1; }
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) { fprintf(stderr, "[MacShack] swap: cannot open %s (errno %d): off\n", path, errno); return -1; }
    if (unlink(path)) {   // the file must not survive the process (especially after jetsam)
        int e = errno; fprintf(stderr, "[MacShack] swap: cannot unlink %s (errno %d): off\n", path, e);
        close(fd); errno = e; return -1;
    }
    struct statfs fs;   // never promise more than the disk has, less 2 GB for everything else
    uint64_t freeMB = 0;
    if (fstatfs(fd, &fs) == 0 && fs.f_bsize > 0) {
        uint64_t blocks = (uint64_t)fs.f_bavail, blockSize = (uint64_t)fs.f_bsize;
        freeMB = blocks > UINT64_MAX / blockSize ? UINT64_MAX >> 20 : blocks * blockSize >> 20;
    }
    uint64_t allowedMB = freeMB > 2048 + 256 ? freeMB - 2048 : 0;
    if (capMB > allowedMB) capMB = allowedMB;
    size_t page = (size_t)getpagesize();
    if (capMB > (SIZE_MAX >> 20)) { close(fd); errno = EOVERFLOW; return -1; }
    size_t len = ((size_t)capMB << 20) / (page * 64) * (page * 64);   // whole bitmap words
    void *base = MAP_FAILED;
    if (capMB >= 256 && ftruncate(fd, (off_t)len) == 0) base = realMmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        fprintf(stderr, "[MacShack] swap: no arena (%llu MB free on disk, errno %d): off\n", (unsigned long long)freeMB, errno);
        close(fd); return -1;
    }
    size_t cacheLen = 0; const void *cache = _dyld_get_shared_cache_range(&cacheLen);
    gCacheLo = (uintptr_t)cache; gCacheHi = gCacheLo + cacheLen;
    gMap = calloc(len / page / 64, sizeof *gMap);
    if (!gMap) { int e = errno ? errno : ENOMEM; munmap(base, len); close(fd); errno = e; return -1; }
    gPage = page; gPages = len / page; gMmap = realMmap; gFd = fd; gBase = base;
    fprintf(stderr, "[MacShack] swap: file-backed arena %p, %zu MB\n", base, len >> 20);
    return 0;
}

static int bit(size_t i) { return (int)(gMap[i >> 6] >> (i & 63) & 1); }
static size_t setBits(size_t first, size_t n, int v) {   // returns how many bits changed
    size_t changed = 0;
    for (size_t i = first; i < first + n; i++)
        if (bit(i) != v) { gMap[i >> 6] ^= 1ull << (i & 63); changed++; }
    return changed;
}
static long findRun(size_t n) {   // next-fit run of n free pages; runs do not wrap past the end
    size_t i = gCursor, run = 0, start = 0;
    for (size_t scanned = 0; scanned < 2 * gPages;) {
        if (i >= gPages) { i = 0; run = 0; }
        if (!(i & 63) && gMap[i >> 6] == ~0ull) { i += 64; scanned += 64; run = 0; continue; }   // skip full words
        if (bit(i)) run = 0;
        else { if (!run) start = i; if (++run == n) { gCursor = i + 1; return (long)start; } }
        i++; scanned++;
    }
    return -1;
}
static uintptr_t arenaLo(void) { return (uintptr_t)gBase; }
static uintptr_t arenaHi(void) { return arenaLo() + gPages * gPage; }
static int fromSystem(void *caller) { return (uintptr_t)caller >= gCacheLo && (uintptr_t)caller < gCacheHi; }

// Round the kernel-visible range to pages without wrapping. Return whether it intersects the arena and whether the
// complete rounded range is contained by it. An overflowing range is never contained.
static int rangeInArena(const void *p, size_t len, size_t *rounded, int *contained) {
    uintptr_t lo = (uintptr_t)p, hi;
    if (len > SIZE_MAX - (gPage - 1)) { *rounded = 0; hi = UINTPTR_MAX; }
    else {
        *rounded = (len + gPage - 1) / gPage * gPage;
        hi = *rounded > UINTPTR_MAX - lo ? UINTPTR_MAX : lo + *rounded;
    }
    int intersects = gBase && lo < arenaHi() && hi > arenaLo();
    *contained = intersects && *rounded && lo >= arenaLo() && *rounded <= arenaHi() - lo;
    return intersects;
}

// Fresh zero pages with `prot` at [p, p+len) in the arena: drop the file data, then map the range again (which also
// replaces whatever mapping the guest may have put there and resets its protection).
static int reset(char *p, size_t len, int prot) {
    off_t off = (off_t)((uintptr_t)p - arenaLo());
    struct fpunchhole ph = { .fp_offset = off, .fp_length = (off_t)len };
#ifdef SHACK_SWAP_TEST
    int punched = gPunchError ? (errno = gPunchError, -1) : fcntl(gFd, F_PUNCHHOLE, &ph);
#else
    int punched = fcntl(gFd, F_PUNCHHOLE, &ph);
#endif
    if (punched) {
        int e = errno; static int said;
        if (said++ < 8) fprintf(stderr, "[MacShack] swap: punch hole failed errno %d\n", e);
        errno = e; return -1;
    }
    if (gMmap(p, len, prot, MAP_FIXED | MAP_SHARED, gFd, off) == MAP_FAILED) {
        int e = errno; static int said;
        if (said++ < 8) fprintf(stderr, "[MacShack] swap: remap %p failed errno %d\n", (void *)p, e);
        errno = e; return -1;
    }
    return 0;
}

void *ShackSwapMmap(void *addr, size_t len, int prot, int flags, int fd, off_t off, void *caller, ShackMmapFn orig) {
    if (!gBase || !len) return orig(addr, len, prot, flags, fd, off);
    size_t bytes; int contained;
    int intersects = rangeInArena(addr, len, &bytes, &contained);
    if (!bytes) {
        if ((flags & MAP_FIXED) && intersects) { errno = EINVAL; return MAP_FAILED; }
        return orig(addr, len, prot, flags, fd, off);
    }
    size_t n = bytes / gPage;
    int anonData = (flags & ~(MAP_PRIVATE | MAP_ANON | MAP_FIXED)) == 0
        && (flags & (MAP_PRIVATE | MAP_ANON)) == (MAP_PRIVATE | MAP_ANON)
        && !(prot & ~(PROT_READ | PROT_WRITE)) && fd == -1 && !fromSystem(caller);
    if (flags & MAP_FIXED) {
        char *p = addr;
        if (intersects && !contained) { errno = EINVAL; return MAP_FAILED; }   // never let the kernel replace only part of the arena
        if (!contained) return orig(addr, len, prot, flags, fd, off);
        if ((uintptr_t)p & (gPage - 1)) { errno = EINVAL; return MAP_FAILED; }
        os_unfair_lock_lock(&gLock);   // a fixed mapping may claim pages which were free when this call began
        if (anonData) {   // the guest (de)commits its own arena pages: emulate it on the file mapping
            if (reset(p, bytes, prot)) { int e = errno; os_unfair_lock_unlock(&gLock); errno = e; return MAP_FAILED; }
        } else {          // something else (a file, code) over arena pages: a real mapping; munmap brings them back
            void *r = orig(addr, len, prot, flags, fd, off);
            if (r == MAP_FAILED) { int e = errno; os_unfair_lock_unlock(&gLock); errno = e; return r; }
            gForeign += n;
        }
        gUsed += setBits(((uintptr_t)p - arenaLo()) / gPage, n, 1); if (gUsed > gPeak) gPeak = gUsed;
        os_unfair_lock_unlock(&gLock);
        return p;
    }
    if (!anonData || prot != (PROT_READ | PROT_WRITE) || addr)
        return orig(addr, len, prot, flags, fd, off);
    os_unfair_lock_lock(&gLock);
    long s = findRun(n);
    if (s >= 0) { gUsed += setBits((size_t)s, n, 1); if (gUsed > gPeak) gPeak = gUsed; } else gRefused++;
    os_unfair_lock_unlock(&gLock);
    return s >= 0 ? gBase + (size_t)s * gPage : orig(addr, len, prot, flags, fd, off);   // free pages are already zero and RW
}

int ShackSwapMunmap(void *addr, size_t len, void *caller, ShackMunmapFn orig) {
    (void)caller;
    if (!gBase || !len) return orig(addr, len);
    size_t bytes; int contained;
    int intersects = rangeInArena(addr, len, &bytes, &contained);
    if (intersects && !contained) { errno = EINVAL; return -1; }   // forwarding would tear a hole in the arena behind the bitmap
    if (!contained) return orig(addr, len);
    char *p = addr;
    if (((uintptr_t)p & (gPage - 1)) || !bytes) { errno = EINVAL; return -1; }
    size_t n = bytes / gPage;
    os_unfair_lock_lock(&gLock);
    if (reset(p, bytes, PROT_READ | PROT_WRITE)) { int e = errno; os_unfair_lock_unlock(&gLock); errno = e; return -1; }
    gUsed -= setBits(((uintptr_t)p - arenaLo()) / gPage, n, 0);
    os_unfair_lock_unlock(&gLock);
    return 0;
}

void ShackSwapStats(char *buf, size_t n) {
    if (!gBase) { snprintf(buf, n, "swap off"); return; }
    os_unfair_lock_lock(&gLock);
    snprintf(buf, n, "swap %llu MB file-backed (peak %llu of %zu, %llu refused, %llu foreign pages)",
             (unsigned long long)(gUsed * gPage >> 20), (unsigned long long)(gPeak * gPage >> 20), gPages * gPage >> 20,
             (unsigned long long)gRefused, (unsigned long long)gForeign);
    os_unfair_lock_unlock(&gLock);
}
