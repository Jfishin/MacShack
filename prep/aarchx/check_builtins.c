// MacShack check: compiler-rt builtins bridged from libSystem (__divdc3 and friends: Unity 2019's Mono imports
// __divdc3; __udivti3 and the other 128-bit divisions). Run under `ocerz -native`; prints "builtins ok".
#include <complex.h>
#include <stdio.h>
int main(int argc, char **argv) {
    volatile double k = argc;   // keeps the calls out of constant folding
    double complex a = (3.0 + 4.0 * I) * k, b = (1.0 - 2.0 * I) * k;
    float complex c = (1.5f + 2.5f * I) * (float)k, d = (0.5f - 1.0f * I) * (float)k;
    double complex q = a / b, m = a * b;
    float complex qf = c / d, mf = c * d;
    double p = __builtin_powi(1.5 * k, 5);
    float pf = __builtin_powif(2.0f * (float)k, -3);
    int ok = creal(q) == -1.0 && cimag(q) == 2.0 && creal(m) == 11.0 && cimag(m) == -2.0 &&
             crealf(qf) == -1.4f && cimagf(qf) == 2.2f && crealf(mf) == 3.25f && cimagf(mf) == -0.25f &&
             p == 7.59375 && pf == 0.125f;
    volatile unsigned __int128 ua = ((unsigned __int128)0x123456789abcdefULL << 64) | 0xfedcba9876543210ULL, ub = 0x1000000007ULL * (unsigned)k;
    volatile __int128 sa = -(__int128)ua, sb = (__int128)ub;
    unsigned __int128 uq = ua / ub, ur = ua % ub;
    __int128 sq = sa / sb, sr = sa % sb;
    ok = ok && uq * ub + ur == ua && ur < ub && sq * sb + sr == sa && sq == -(__int128)uq && sr == -(__int128)ur;
    printf(ok ? "builtins ok\n" : "builtins FAIL %g %g %g %g %g %g %g %g %g %g\n", creal(q), cimag(q), creal(m), cimag(m),
           crealf(qf), cimagf(qf), crealf(mf), cimagf(mf), p, pf);
    return !ok;
}
