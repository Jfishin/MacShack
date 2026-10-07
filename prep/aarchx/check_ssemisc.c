// MacShack check: shuffles, sign masks, packed compares, cvttps2dq and reciprocal estimates that AArchX's JIT inlines
// (emit_sse_misc) against scalar references. Run under `ocerz -native`; prints "ssemisc ok N".
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct { union { float f[4]; double d[2]; uint32_t u[4]; uint16_t w[8]; int32_t i[4]; uint64_t q[2]; }; } __attribute__((aligned(16))) V;
static uint32_t seed = 777;
static uint32_t rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }
static float rf(void) {
    switch (rnd() % 12) {
    case 0: return NAN; case 1: return INFINITY; case 2: return -INFINITY; case 3: return 0.0f; case 4: return 3e9f; case 5: return -3e9f;
    default: return ((float)(rnd() % 20001) - 10000.0f) / 37.0f;
    }
}
#define RR(ins, x) __asm__ volatile("movdqa %0, %%xmm0\n movdqa %1, %%xmm1\n " ins " %%xmm1, %%xmm0\n movdqa %%xmm0, %0" : "+m"(*d) : "m"(*s) : "xmm0", "xmm1")
#define RM(ins) __asm__ volatile("movdqa %0, %%xmm2\n " ins " %1, %%xmm2\n movdqa %%xmm2, %0" : "+m"(*d) : "m"(*s) : "xmm2")
static int fails, n;
static void same(const char *what, const V *want, const V *got) {
    n++;
    if (memcmp(want, got, 16)) { if (fails++ < 5) printf("ssemisc FAIL %s: want %08x %08x %08x %08x got %08x %08x %08x %08x\n", what, want->u[0], want->u[1], want->u[2], want->u[3], got->u[0], got->u[1], got->u[2], got->u[3]); }
}
int main(void) {
    for (int it = 0; it < 3000; it++) {
        V a, b, w, g, *d = &g, *s = &b;
        for (int i = 0; i < 4; i++) { a.f[i] = rf(); b.f[i] = rf(); }
        if (it % 3 == 0) for (int i = 0; i < 2; i++) { a.d[i] = rf(); b.d[i] = rf(); }
        // movshdup / movsldup
        w = b; w.u[0] = w.u[1]; w.u[2] = w.u[3]; g = a; RR("movshdup", 0); same("movshdup", &w, &g);
        w = b; w.u[1] = w.u[0]; w.u[3] = w.u[2]; g = a; RM("movsldup"); same("movsldup", &w, &g);
        // pshuflw / pshufhw imm 0x1b and 0xd8
        w = b; for (int i = 0; i < 4; i++) w.w[i] = b.w[(0x1b >> (2 * i)) & 3]; g = a; __asm__ volatile("movdqa %1, %%xmm1\n pshuflw $0x1b, %%xmm1, %%xmm0\n movdqa %%xmm0, %0" : "=m"(g) : "m"(b) : "xmm0", "xmm1"); same("pshuflw", &w, &g);
        w = b; for (int i = 0; i < 4; i++) w.w[4 + i] = b.w[4 + ((0xd8 >> (2 * i)) & 3)]; __asm__ volatile("pshufhw $0xd8, %1, %%xmm3\n movdqa %%xmm3, %0" : "=m"(g) : "m"(b) : "xmm3"); same("pshufhw", &w, &g);
        // movmskps / movmskpd
        int mk, want = 0;
        for (int i = 0; i < 4; i++) want |= (int)(b.u[i] >> 31) << i;
        __asm__ volatile("movdqa %1, %%xmm4\n movmskps %%xmm4, %0" : "=r"(mk) : "m"(b) : "xmm4"); n++; if (mk != want && fails++ < 5) printf("ssemisc FAIL movmskps %x %x\n", mk, want);
        want = (int)(b.q[0] >> 63) | (int)(b.q[1] >> 63) << 1;
        __asm__ volatile("movdqa %1, %%xmm5\n movmskpd %%xmm5, %0" : "=r"(mk) : "m"(b) : "xmm5"); n++; if (mk != want && fails++ < 5) printf("ssemisc FAIL movmskpd %x %x\n", mk, want);
        // cmpps / cmppd, all 8 predicates
        for (int p = 0; p < 8; p++) {
            for (int i = 0; i < 4; i++) {
                float x = a.f[i], y = b.f[i]; int un = isnan(x) || isnan(y), r;
                switch (p) { case 0: r = !un && x == y; break; case 1: r = !un && x < y; break; case 2: r = !un && x <= y; break; case 3: r = un; break;
                case 4: r = un || x != y; break; case 5: r = un || !(x < y); break; case 6: r = un || !(x <= y); break; default: r = !un; }
                w.u[i] = r ? 0xffffffffu : 0;
            }
            g = a;
            switch (p) {
            case 0: RR("cmpps $0,", 0); break; case 1: RR("cmpps $1,", 0); break; case 2: RR("cmpps $2,", 0); break; case 3: RR("cmpps $3,", 0); break;
            case 4: RR("cmpps $4,", 0); break; case 5: RR("cmpps $5,", 0); break; case 6: RR("cmpps $6,", 0); break; default: RR("cmpps $7,", 0);
            }
            same("cmpps", &w, &g);
        }
        for (int i = 0; i < 2; i++) { double x = a.d[i], y = b.d[i]; w.q[i] = (!isnan(x) && !isnan(y) && x < y) ? ~0ull : 0; }
        g = a; RM("cmppd $1,"); same("cmppd lt", &w, &g);
        // cvttps2dq: out of range and NaN give 0x80000000
        for (int i = 0; i < 4; i++) { float x = b.f[i]; w.i[i] = isnan(x) || fabsf(x) >= 2147483648.0f ? (int32_t)0x80000000u : (int32_t)x; }
        g = a; RR("cvttps2dq", 0); same("cvttps2dq", &w, &g);
        // psrldq / pslldq, haddps / haddpd, blendps / blendpd
        V bb = b; unsigned char *bp = (unsigned char *)&bb, *wp = (unsigned char *)&w;
        for (int i = 0; i < 16; i++) wp[i] = i + 5 < 16 ? bp[i + 5] : 0;
        g = b; __asm__ volatile("movdqa %0, %%xmm8\n psrldq $5, %%xmm8\n movdqa %%xmm8, %0" : "+m"(g) :: "xmm8"); same("psrldq", &w, &g);
        for (int i = 0; i < 16; i++) wp[i] = i >= 3 ? bp[i - 3] : 0;
        g = b; __asm__ volatile("movdqa %0, %%xmm9\n pslldq $3, %%xmm9\n movdqa %%xmm9, %0" : "+m"(g) :: "xmm9"); same("pslldq", &w, &g);
        w.f[0] = a.f[0] + a.f[1]; w.f[1] = a.f[2] + a.f[3]; w.f[2] = b.f[0] + b.f[1]; w.f[3] = b.f[2] + b.f[3];
        g = a; RR("haddps", 0);
        for (int i = 0; i < 4; i++) if (isnan(w.f[i]) && isnan(g.f[i])) g.u[i] = w.u[i];   /* NaN payloads may differ */
        same("haddps", &w, &g);
        w.d[0] = a.d[0] + a.d[1]; w.d[1] = b.d[0] + b.d[1];
        g = a; RM("haddpd");
        for (int i = 0; i < 2; i++) if (isnan(w.d[i]) && isnan(g.d[i])) g.q[i] = w.q[i];
        same("haddpd", &w, &g);
        for (int i = 0; i < 4; i++) w.u[i] = (0xb >> i) & 1 ? b.u[i] : a.u[i];
        g = a; RR("blendps $0xb,", 0); same("blendps", &w, &g);
        w.q[0] = a.q[0]; w.q[1] = b.q[1];
        g = a; RM("blendpd $2,"); same("blendpd", &w, &g);
        // rcpps / rsqrtps: within x86's 1.5 * 2^-12 relative error; zeros, infinities and signs exact
        V rc, rs;
        __asm__ volatile("rcpps %1, %%xmm6\n movdqa %%xmm6, %0" : "=m"(rc) : "m"(b) : "xmm6");
        __asm__ volatile("rsqrtps %1, %%xmm7\n movdqa %%xmm7, %0" : "=m"(rs) : "m"(b) : "xmm7");
        for (int i = 0; i < 4; i++) {
            float x = b.f[i], r1 = 1.0f / x, r2 = 1.0f / sqrtf(x); n += 2;
            int ok1 = isnan(x) ? isnan(rc.f[i]) : isinf(r1) || r1 == 0 ? rc.f[i] == r1 : fabsf(rc.f[i] - r1) <= fabsf(r1) * 3.7e-4f;
            int ok2 = isnan(r2) ? isnan(rs.f[i]) : isinf(r2) || r2 == 0 ? rs.f[i] == r2 : fabsf(rs.f[i] - r2) <= fabsf(r2) * 3.7e-4f;
            if ((!ok1 || !ok2) && fails++ < 5) printf("ssemisc FAIL rcp/rsqrt x=%g: %g (%g) %g (%g)\n", x, rc.f[i], r1, rs.f[i], r2);
        }
    }
    if (!fails) printf("ssemisc ok %d\n", n);
    return fails != 0;
}
