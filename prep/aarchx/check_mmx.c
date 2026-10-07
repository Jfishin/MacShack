// MMX moves, which the JIT used to leave to the interpreter: BioShock's WebM decoder ran ~1.1 billion movq/movd per
// two minutes of video there. Every form (mm<->mm, mm<->m64/m32, mm<->r64/r32, indexed stores), and the x87 tag word
// and TOP an MMX instruction leaves behind. `ocerz -native` must print exactly what `ocerz -native -no-jit` prints; the
// checksum must also match Rosetta (Rosetta's x87 tag word after MMX is its own, as is AArchX's).
// clang -arch x86_64 check_mmx.c -o /tmp/c && ./ocerz -native /tmp/c   # mmx ok 2dab7468d93168e0 tags 00ff top 0 empty 0000
#include <stdint.h>
#include <stdio.h>

static uint64_t fill[64];

int main(void) {
    uint64_t sum = 0;
    for (uint64_t it = 1; it <= 200000; it++) {   // hot, so the JIT translates it
        uint64_t src = 0x0123456789abcdefull * it, out64 = 0, r64 = 0, out5 = 0, out6 = 0, hi = 1;
        uint32_t out32 = 0, r32 = 0;
        __asm__ volatile(
            "movq %[src], %%mm1\n\t"      // mm <- m64
            "movq %%mm1, %%mm2\n\t"       // mm <- mm
            "movq %%mm2, %[out64]\n\t"    // m64 <- mm
            "movd %%mm1, %[r32]\n\t"      // r32 <- mm
            "movd %[r32], %%mm3\n\t"      // mm <- r32 (zero-extended)
            "movd %%mm3, %[out32]\n\t"    // m32 <- mm
            "movq %%mm1, %[r64]\n\t"      // r64 <- mm
            "movq %[r64], %%mm4\n\t"      // mm <- r64
            "movd %[src], %%mm5\n\t"      // mm <- m32 (zero-extended)
            "movq %%mm5, %[out5]\n\t"
            "movq %%mm4, %%mm7\n\t"
            "movq2dq %%mm1, %%xmm1\n\t"  // xmm <- mm (the high quadword becomes 0)
            "movdq2q %%xmm1, %%mm6\n\t"  // mm <- xmm
            "movq %%mm6, %[out6]\n\t"
            "movhlps %%xmm1, %%xmm2\n\t"
            "movq %%xmm2, %[hi]\n\t"
            "emms\n\t"
            : [out64] "=m"(out64), [out32] "=m"(out32), [r32] "+r"(r32), [r64] "+r"(r64), [out5] "=m"(out5),
              [out6] "=m"(out6), [hi] "=m"(hi)
            : [src] "m"(src)
            : "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7", "xmm1", "xmm2");
        // the video's fill loop: movq [rdi+rcx*2], mm1
        __asm__ volatile(
            "movq %[v], %%mm1\n\t"
            "xor %%ecx, %%ecx\n\t"
            "1: movq %%mm1, (%[p],%%rcx,2)\n\t"
            "add $4, %%rcx\n\t"
            "cmp $128, %%rcx\n\t"
            "jb 1b\n\t"
            "emms\n\t"
            :
            : [v] "m"(src), [p] "r"(fill)
            : "rcx", "mm1", "memory", "cc");
        if (out64 != src || out32 != (uint32_t)src || r32 != (uint32_t)src || r64 != src || out5 != (uint32_t)src ||
            out6 != src || hi != 0 || fill[it & 31] != src) {
            printf("mmx FAIL at %llu\n", (unsigned long long)it);
            return 1;
        }
        sum = sum * 31 + out64 + out32 + r64 + out5 + out6;
    }
    // An MMX instruction sets TOP to 0 and tags every register valid; EMMS empties them. Read both states back.
    uint16_t env[14];
    __asm__ volatile("movq %%mm0, %%mm0\n\tfnstenv %0\n\temms" : "=m"(env) : : "mm0");
    uint16_t tags_after_mmx = env[4];
    __asm__ volatile("fnstenv %0" : "=m"(env));
    printf("mmx ok %016llx tags %04x top %d empty %04x\n", (unsigned long long)sum, tags_after_mmx,
           (env[2] >> 11) & 7, env[4]);
    return 0;
}
