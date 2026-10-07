// MacShack check: scalar SSE results carried around a dec/jne loop (AArchX's fused inc/dec+jcc dropped them when the
// loop kept a fixed l0 register mapping; FMOD 1.10's EQ blew up). Run under `ocerz -native`; prints "l0loop ok".
#include <stdio.h>
__attribute__((noinline)) static void accumulate(int n, const float *d, float *out) {
    __asm__ volatile(
        "movss (%[d]), %%xmm10\n movss 4(%[d]), %%xmm12\n movss 8(%[d]), %%xmm13\n"
        "xorps %%xmm3, %%xmm3\n xorps %%xmm5, %%xmm5\n xorps %%xmm6, %%xmm6\n xorps %%xmm2, %%xmm2\n"
        "1:\n movaps %%xmm6, %%xmm1\n mulss %%xmm1, %%xmm1\n addss %%xmm1, %%xmm2\n"
        "addss %%xmm10, %%xmm6\n addss %%xmm12, %%xmm5\n addss %%xmm13, %%xmm3\n"
        "movaps %%xmm2, %%xmm7\n decl %[n]\n jne 1b\n"
        "movss %%xmm6, (%[o])\n movss %%xmm5, 4(%[o])\n movss %%xmm3, 8(%[o])\n movss %%xmm7, 12(%[o])\n"
        : [n] "+r"(n) : [d] "r"(d), [o] "r"(out) : "memory", "xmm1", "xmm2", "xmm3", "xmm5", "xmm6", "xmm7", "xmm10", "xmm12", "xmm13");
}
int main(void) {
    const float d[3] = {1e-4f, -2e-4f, 1e-5f};
    for (int n = 1; n <= 64; n++) {
        float got[4], a = 0, b = 0, c = 0, sq = 0;
        accumulate(n, d, got);
        for (int i = 0; i < n; i++) { sq += a * a; a += d[0]; b += d[1]; c += d[2]; }
        if (got[0] != a || got[1] != b || got[2] != c || got[3] != sq) {
            printf("l0loop FAIL n=%d: %g %g %g %g want %g %g %g %g\n", n, got[0], got[1], got[2], got[3], a, b, c, sq);
            return 1;
        }
    }
    printf("l0loop ok\n");
    return 0;
}
