// Mac check of host/ShackSwap.c: clang -Ihost host/ShackSwap.c host/probe/test_swap.c -o /tmp/t && /tmp/t
// Add -DSHACK_SWAP_TEST to exercise failed-hole-punch handling as well.
#include "ShackSwap.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static const size_t MB = 1 << 20;
static const int RW = PROT_READ | PROT_WRITE, ANON = MAP_PRIVATE | MAP_ANON;
static void *me;
static uint64_t footprintMB(void) {
    task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n); return v.phys_footprint >> 20;
}
static unsigned long long usedMB(void) { char s[200]; unsigned long long mb = 0; ShackSwapStats(s, sizeof s); sscanf(s, "swap %llu", &mb); return mb; }
static int allZero(const char *p, size_t n) { for (size_t i = 0; i < n; i += 4096) if (p[i] || p[i + 4095]) return 0; return 1; }
static void *map(size_t len) { return ShackSwapMmap(NULL, len, RW, ANON, -1, 0, me, mmap); }
static int unmap(void *p, size_t len) { return ShackSwapMunmap(p, len, me, munmap); }

static void *stress(void *arg) {   // random sizes, each block stamped and checked: no overlap, zero on arrival
    unsigned seed = (unsigned)(uintptr_t)arg; char tag = (char)(uintptr_t)arg;
    struct { char *p; size_t len; } live[64] = {0};
    for (int i = 0; i < 20000; i++) {
        int k = rand_r(&seed) % 64;
        if (live[k].p) {
            for (size_t o = 0; o < live[k].len; o += 16384) assert(live[k].p[o] == tag);
            assert(unmap(live[k].p, live[k].len) == 0); live[k].p = NULL;
        } else {
            size_t len = (size_t)(1 + rand_r(&seed) % 64) * 16384 - (rand_r(&seed) % 2 ? 100 : 0);
            char *p = map(len); assert(p != MAP_FAILED && allZero(p, len & ~(size_t)4095));
            for (size_t o = 0; o < len; o += 16384) p[o] = tag;
            live[k].p = p; live[k].len = len;
        }
    }
    for (int k = 0; k < 64; k++) if (live[k].p) unmap(live[k].p, live[k].len);
    return NULL;
}

int main(void) {
    me = (void *)main; void *sys = (void *)printf;   // a guest-image caller, and a shared-cache one
    assert(ShackSwapInit("/tmp/shack-swap-test.bin", 2048, mmap) == 0);
    assert(access("/tmp/shack-swap-test.bin", F_OK) != 0);   // unlinked

    uint64_t f0 = footprintMB();
    char *a = map(512 * MB);
    assert(a != MAP_FAILED && usedMB() == 512 && allZero(a, 512 * MB));
    memset(a, 0x5a, 512 * MB);
    uint64_t f1 = footprintMB();
    printf("footprint %llu -> %llu MB after writing 512 MB\n", f0, f1);
    assert(f1 - f0 < 64);

    // The wrapper must preserve native validation instead of accepting malformed anonymous mappings.
    errno = 0;
    assert(ShackSwapMmap(NULL, 16384, RW, MAP_ANON, -1, 0, me, mmap) == MAP_FAILED && errno == EINVAL);
    // Fixed mappings and unmaps which cross an arena boundary must not tear out pages behind the bitmap.
    size_t page = (size_t)getpagesize();
    char *beforeArena = (char *)((uintptr_t)a - page);
    errno = 0;
    assert(ShackSwapMmap(beforeArena, 2 * page, RW, MAP_FIXED | ANON, -1, 0, me, mmap) == MAP_FAILED && errno == EINVAL);
    errno = 0;
    assert(unmap(beforeArena, 2 * page) == -1 && errno == EINVAL && a[0] == 0x5a && usedMB() == 512);
    errno = 0;
    assert(ShackSwapMmap(a, SIZE_MAX, RW, MAP_FIXED | ANON, -1, 0, me, mmap) == MAP_FAILED && errno == EINVAL);
    errno = 0;
    assert(unmap(a, SIZE_MAX) == -1 && errno == EINVAL && usedMB() == 512);
    // Address hints and mapping attributes which the arena cannot preserve stay on the native path.
    void *hinted = ShackSwapMmap(a + 128 * MB, page, RW, ANON, -1, 0, me, mmap);
    assert(hinted != MAP_FAILED && usedMB() == 512); munmap(hinted, page);
    void *noCache = ShackSwapMmap(NULL, page, RW, ANON | MAP_NOCACHE, -1, 0, me, mmap);
    assert(noCache != MAP_FAILED && usedMB() == 512); munmap(noCache, page);

#ifdef SHACK_SWAP_TEST
    char *failed = map(page); assert(failed != MAP_FAILED); failed[0] = 0x6b;
    unsigned long long beforeFailure = usedMB();
    ShackSwapTestFailPunch(ENOSPC); errno = 0;
    assert(unmap(failed, page) == -1 && errno == ENOSPC && failed[0] == 0x6b && usedMB() == beforeFailure);
    ShackSwapTestFailPunch(0); assert(unmap(failed, page) == 0);
#endif

    assert(unmap(a + 128 * MB, 128 * MB) == 0 && usedMB() == 384);
    assert(allZero(a + 128 * MB, 128 * MB) && a[0] == 0x5a && a[511 * MB] == 0x5a);   // punched: zero, neighbours intact
    char *b = map(64 * MB); assert(b != MAP_FAILED && usedMB() == 448 && allZero(b, 64 * MB));
    memset(b, 1, 64 * MB);

    // An allocator decommitting and recommitting its own pages with MAP_FIXED.
    assert(ShackSwapMmap(a, 64 * MB, PROT_NONE, MAP_FIXED | ANON, -1, 0, me, mmap) == a && usedMB() == 448);
    assert(ShackSwapMmap(a, 64 * MB, RW, MAP_FIXED | ANON, -1, 0, me, mmap) == a && allZero(a, 64 * MB));
    // A file mapped over arena pages is real; unmapping it returns the pages.
    int fd = open("/tmp/shack-swap-file.bin", O_RDWR | O_CREAT | O_TRUNC, 0600); unlink("/tmp/shack-swap-file.bin");
    ftruncate(fd, 16 * MB); pwrite(fd, "hi", 2, 0);
    assert(ShackSwapMmap(b, 16 * MB, PROT_READ, MAP_FIXED | MAP_SHARED, fd, 0, me, mmap) == b && !memcmp(b, "hi", 2));
    assert(unmap(b, 16 * MB) == 0 && allZero(b, 16 * MB) && usedMB() == 432);

    char *small = map(100); assert(small != MAP_FAILED && (size_t)(small - a) < 2048 * MB);   // small maps come from the arena too (a = its start)
    unmap(small, 100);
    void *exec = ShackSwapMmap(NULL, 16 * MB, RW | PROT_EXEC, ANON, -1, 0, me, mmap);
    void *fromSys = ShackSwapMmap(NULL, 16 * MB, RW, ANON, -1, 0, sys, mmap);
    assert(fromSys != MAP_FAILED && usedMB() == 432);
    (void)exec;
    assert(unmap(a, 512 * MB) == 0 && unmap(b + 16 * MB, 48 * MB) == 0 && usedMB() == 0);

    pthread_t t[8];
    for (uintptr_t i = 0; i < 8; i++) pthread_create(&t[i], NULL, stress, (void *)(i + 1));
    for (int i = 0; i < 8; i++) pthread_join(t[i], NULL);
    char s[200]; ShackSwapStats(s, sizeof s); printf("%s\n", s);
    assert(usedMB() == 0);
    puts("OK");
    return 0;
}
