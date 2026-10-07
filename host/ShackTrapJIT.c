// Stock Unity Mono without a rebuild. iOS never writes and executes one address, so executable memory is the
// debugger-prepared RX pool with an RW alias (ShackJITPoolSetup). The game's own libmonobdwgc writes code at the RX
// address: its memcpy/memset-family writes into the pool are redirected to the alias, and every other store faults
// (SIGBUS) and is replayed here on the alias before the PC skips it. Generated code is unchanged; compiling costs about
// 2x (Mac: ~13 traps per method, ~2 us each). Proof and gotchas: prep/unity-mono/trapjit/README.md.
#include "ShackTrapJIT.h"
#include "vendor/fishhook.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <libkern/OSCacheControl.h>

void *__memcpy_chk(void *, const void *, size_t, size_t);
void *__memmove_chk(void *, const void *, size_t, size_t);
void *__memset_chk(void *, int, size_t, size_t);

static char *rx, *rx_end;   // set only once active: every check below is false until then
static ptrdiff_t delta;
static size_t pool_size, next_off;
static unsigned long traps;
static char monoPath[1024];   // set when libmonobdwgc loads (onImage)

static inline int inpool(const void *p) { return (const char *)p >= rx && (const char *)p < rx_end; }
int ShackTrapJITOwns(const void *p) { return inpool(p); }
#define W(d) (inpool(d) ? (void *)((char *)(d) + delta) : (void *)(d))

// Decided at the first executable mmap, when Mono is loaded: the rebuild exports its pool bookkeeping.
static int activate(void) {
    static int state;   // 0 undecided, 1 active, -1 not ours
    if (state) return state > 0;
    unsigned long long r = 0, w = 0, s = 0;
    const char *env = getenv("SHACK_JIT_POOL");
    if (!env || sscanf(env, "%llx,%llx,%llx", &r, &w, &s) != 3 || !r || !w || !s) return 0;
    void *mono = monoPath[0] ? dlopen(monoPath, RTLD_LAZY | RTLD_NOLOAD) : NULL;   // Unity may load it RTLD_LOCAL
    if (!mono) return 0;   // Mono not loaded yet
    int rebuilt = dlsym(mono, "mono_codeman_pool_rx") != NULL;
    dlclose(mono);
    if (rebuilt) { state = -1; return 0; }
    delta = (char *)(uintptr_t)w - (char *)(uintptr_t)r; pool_size = s;
    rx_end = (char *)(uintptr_t)r + s; rx = (char *)(uintptr_t)r;
    state = 1;
    fprintf(stderr, "[ShackTrapJIT] stock Mono: code stores into the %llu MB pool are replayed on its RW alias\n", s >> 20);
    return 1;
}

void *ShackTrapJITAlloc(size_t len) {
    if (!activate()) return NULL;
    len = (len + 16383) & ~(size_t)16383;
    size_t off = __atomic_fetch_add(&next_off, len, __ATOMIC_RELAXED);
    if (off + len <= pool_size) return rx + off;
    fprintf(stderr, "[ShackTrapJIT] JIT pool exhausted (%zu MB): raise --shack-jit-mb in the game's .args\n", pool_size >> 20);
    return NULL;   // ponytail: bump only, freed code chunks are not reused; add a free list if a game exhausts the pool
}

// ---- libmonobdwgc imports ----------------------------------------------------------------------------------
static void *t_memcpy(void *d, const void *s, size_t n) { memcpy(W(d), s, n); return d; }
static void *t_memmove(void *d, const void *s, size_t n) { memmove(W(d), s, n); return d; }
static void *t_memset(void *d, int c, size_t n) { memset(W(d), c, n); return d; }
static void t_bzero(void *d, size_t n) { bzero(W(d), n); }
static void t_memset_pattern16(void *d, const void *p, size_t n) { memset_pattern16(W(d), p, n); }
static void *t_memcpy_chk(void *d, const void *s, size_t n, size_t l) { __memcpy_chk(W(d), s, n, l); return d; }
static void *t_memmove_chk(void *d, const void *s, size_t n, size_t l) { __memmove_chk(W(d), s, n, l); return d; }
static void *t_memset_chk(void *d, int c, size_t n, size_t l) { __memset_chk(W(d), c, n, l); return d; }
// Changing the pool's protection would cost it execute permission for good (a debugger-prepared page loses max-X).
static int t_mprotect(void *a, size_t l, int p) { return inpool(a) ? 0 : mprotect(a, l, p); }
static void t_icache(void *p, size_t n) { if (inpool(p)) sys_dcache_flush(W(p), n); sys_icache_invalidate(p, n); }

static void onImage(const struct mach_header *mh, intptr_t slide) {
    Dl_info d;
    if (!dladdr(mh, &d) || !d.dli_fname) return;
    size_t n = strlen(d.dli_fname);
    if (n < 22 || strcmp(d.dli_fname + n - 22, "libmonobdwgc-2.0.dylib")) return;
    strlcpy(monoPath, d.dli_fname, sizeof monoPath);
    struct rebinding r[] = {
        {"memcpy", t_memcpy, NULL}, {"memmove", t_memmove, NULL}, {"memset", t_memset, NULL}, {"bzero", t_bzero, NULL},
        {"memset_pattern16", t_memset_pattern16, NULL}, {"__memcpy_chk", t_memcpy_chk, NULL},
        {"__memmove_chk", t_memmove_chk, NULL}, {"__memset_chk", t_memset_chk, NULL},
        {"mprotect", t_mprotect, NULL}, {"sys_icache_invalidate", t_icache, NULL},
    };
    rebind_symbols_image((void *)mh, slide, r, sizeof r / sizeof *r);
}
void ShackTrapJITHookMono(void) { _dyld_register_func_for_add_image(onImage); }

// ---- store replay ------------------------------------------------------------------------------------------
typedef _STRUCT_ARM_THREAD_STATE64 SS;
static uint64_t *xr(SS *s, int n) { return n < 29 ? &s->__x[n] : n == 29 ? &s->__fp : &s->__lr; }
static uint64_t get(SS *s, int n, int sp) { return n == 31 ? (sp ? s->__sp : 0) : *xr(s, n); }
static void set(SS *s, int n, uint64_t v, int sp) { if (n != 31) *xr(s, n) = v; else if (sp) s->__sp = v; }
static int64_t sext(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }

static int put(uint64_t addr, const void *src, int bytes) {
    if (!inpool((void *)addr) || !inpool((void *)(addr + bytes - 1))) return 0;
    void *w = (char *)addr + delta;
    if (addr & (bytes - 1)) { memcpy(w, src, bytes); return 1; }   // stlr needs natural alignment; the guest's str did not
    switch (bytes) {   // aligned: one store, so a thread executing the old instruction never sees a torn one
    case 1: __atomic_store_n((uint8_t *)w, *(const uint8_t *)src, __ATOMIC_RELEASE); break;
    case 2: __atomic_store_n((uint16_t *)w, *(const uint16_t *)src, __ATOMIC_RELEASE); break;
    case 4: __atomic_store_n((uint32_t *)w, *(const uint32_t *)src, __ATOMIC_RELEASE); break;
    case 8: __atomic_store_n((uint64_t *)w, *(const uint64_t *)src, __ATOMIC_RELEASE); break;
    default: memcpy(w, src, bytes);
    }
    return 1;
}
static void val(ucontext_t *uc, int v, int t, int bytes, void *out) {
    if (v) memcpy(out, &uc->uc_mcontext->__ns.__v[t], bytes);
    else { uint64_t x = get(&uc->uc_mcontext->__ss, t, 0); memcpy(out, &x, bytes); }
}

#define ATOMIC_OP(T) { T *p = (T *)w, o; \
    switch (op) { case 0x00: o = __atomic_fetch_add(p, (T)rs, __ATOMIC_SEQ_CST); break; \
                  case 0x01: o = __atomic_fetch_and(p, (T)~rs, __ATOMIC_SEQ_CST); break; \
                  case 0x02: o = __atomic_fetch_xor(p, (T)rs, __ATOMIC_SEQ_CST); break; \
                  case 0x03: o = __atomic_fetch_or(p, (T)rs, __ATOMIC_SEQ_CST); break; \
                  case 0x10: o = __atomic_exchange_n(p, (T)rs, __ATOMIC_SEQ_CST); break; \
                  case 0x20: o = (T)rs; __atomic_compare_exchange_n(p, &o, (T)rtv, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); break; \
                  default: return 0; } old = o; }

// Stores only: STR/STUR/STP (GPR and SIMD; unsigned, unscaled, pre/post index, register offset), STXR/STXP/STLR,
// CAS and the LSE add/clr/eor/set/swp. Anything else returns 0 and the fault goes on to the guest's handler.
static int replay(ucontext_t *uc) {
    SS *s = &uc->uc_mcontext->__ss;
    uint32_t i = *(uint32_t *)s->__pc;
    int rt = i & 31, rn = (i >> 5) & 31, size = i >> 30, v = (i >> 26) & 1, writeback = 0;
    uint64_t base = get(s, rn, 1), addr, wb = 0;
    uint8_t buf[32];

    if ((i & 0x3b000000) == 0x39000000 || (i & 0x3b200000) == 0x38000000 || (i & 0x3b200c00) == 0x38200800) {
        int opc = (i >> 22) & 3, bytes;
        if (opc == 0) bytes = 1 << size; else if (v && opc == 2 && size == 0) bytes = 16; else return 0;
        if ((i & 0x3b000000) == 0x39000000) addr = base + (uint64_t)((i >> 10) & 0xfff) * bytes;
        else if ((i & 0x3b200000) == 0x38000000) {
            int64_t imm = sext((i >> 12) & 0x1ff, 9); int mode = (i >> 10) & 3;
            addr = mode == 1 ? base : base + imm;
            if (mode == 1 || mode == 3) { writeback = 1; wb = base + imm; }
        } else {
            uint64_t m = get(s, (i >> 16) & 31, 0); int opt = (i >> 13) & 7;
            if (opt == 2) m = (uint32_t)m; else if (opt == 6) m = (uint64_t)(int64_t)(int32_t)m;
            if ((i >> 12) & 1) m <<= __builtin_ctz(bytes);
            addr = base + m;
        }
        val(uc, v, rt, bytes, buf);
        if (!put(addr, buf, bytes)) return 0;
    } else if ((i & 0x3a000000) == 0x28000000 && !((i >> 22) & 1)) {        // STP / STNP
        int bytes = v ? 4 << size : (size == 0 ? 4 : size == 2 ? 8 : 0), mode = (i >> 23) & 3;
        if (!bytes) return 0;
        int64_t imm = sext((i >> 15) & 0x7f, 7) * bytes;
        addr = mode == 1 ? base : base + imm;
        if (mode == 1 || mode == 3) { writeback = 1; wb = base + imm; }
        val(uc, v, rt, bytes, buf); val(uc, v, (i >> 10) & 31, bytes, buf + bytes);
        if (!put(addr, buf, bytes) || !put(addr + bytes, buf + bytes, bytes)) return 0;
    } else if ((i & 0x3fa07c00) == 0x08a07c00 || ((i & 0x3f200c00) == 0x38200000 && !v)) {   // CAS, LSE atomics
        int op = (i & 0x3f000000) == 0x08000000 ? 0x20 : (((i >> 15) & 1) << 4) | ((i >> 12) & 7);
        int rsn = (i >> 16) & 31;
        uint64_t rs = get(s, rsn, 0), rtv = get(s, rt, 0), old;
        if (!inpool((void *)base) || (base & ((1 << size) - 1))) return 0;
        void *w = (char *)base + delta;
        switch (size) { case 0: ATOMIC_OP(uint8_t) break; case 1: ATOMIC_OP(uint16_t) break;
                        case 2: ATOMIC_OP(uint32_t) break; default: ATOMIC_OP(uint64_t) }
        set(s, op == 0x20 ? rsn : rt, old, 0);
    } else if ((i & 0x3f000000) == 0x08000000 && !((i >> 22) & 1)) {        // STXR, STXP, STLR
        int o2 = (i >> 23) & 1, o1 = (i >> 21) & 1;
        if (!o2 && !o1) { val(uc, 0, rt, 1 << size, buf); if (!put(base, buf, 1 << size)) return 0; set(s, (i >> 16) & 31, 0, 0); }
        else if (!o2 && o1 && (i >> 31)) {
            int b = 4 << (size & 1); val(uc, 0, rt, b, buf); val(uc, 0, (i >> 10) & 31, b, buf + b);
            if (!put(base, buf, b) || !put(base + b, buf + b, b)) return 0;
            set(s, (i >> 16) & 31, 0, 0);
        } else if (o2 && !o1) { val(uc, 0, rt, 1 << size, buf); if (!put(base, buf, 1 << size)) return 0; }
        else return 0;
    } else return 0;
    if (writeback) set(s, rn, wb, 1);
    s->__pc += 4;
    return 1;
}

int ShackTrapJITFault(siginfo_t *si, void *uc) {
    if (!inpool(si->si_addr)) return 0;
    if (replay(uc)) {
        // A progress line per 2^20 traps: enough to see the JIT working in the game log without flooding it.
        if (!(__atomic_add_fetch(&traps, 1, __ATOMIC_RELAXED) & 0xfffff)) fprintf(stderr, "[ShackTrapJIT] %lu stores replayed, pool %zu MB used\n", traps, next_off >> 20);
        return 1;
    }
    SS *s = &((ucontext_t *)uc)->uc_mcontext->__ss;
    fprintf(stderr, "[ShackTrapJIT] unhandled instruction %08x at pc %llx writing %p\n", *(uint32_t *)s->__pc, s->__pc, si->si_addr);
    return 0;
}
