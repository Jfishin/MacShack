// MacShack check: SSE packs, multiply-high and multiply-add that AArchX's JIT inlines (emit_sse_packmul) against
// scalar references. Run under `ocerz -native`; prints "packmul ok N".
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct { union { uint8_t b[16]; int8_t sb[16]; int16_t w[8]; uint16_t uw[8]; int32_t d[4]; }; } __attribute__((aligned(16))) V;
static uint32_t seed = 12345;
static uint32_t rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }
static int16_t sat16(int v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : v; }
static int8_t sat8s(int v) { return v > 127 ? 127 : v < -128 ? -128 : v; }
static uint8_t sat8u(int v) { return v > 255 ? 255 : v < 0 ? 0 : v; }
static uint16_t sat16u(int32_t v) { return v > 65535 ? 65535 : v < 0 ? 0 : v; }

static void ref(int op, V *d, const V *s) {
    V r; memset(&r, 0, sizeof r);
    switch (op) {
    case 0: for (int i = 0; i < 8; i++) r.w[i] = (int16_t)(((int32_t)d->w[i] * s->w[i]) >> 16); break;           // pmulhw
    case 1: for (int i = 0; i < 8; i++) r.uw[i] = (uint16_t)(((uint32_t)d->uw[i] * s->uw[i]) >> 16); break;     // pmulhuw
    case 2: for (int i = 0; i < 4; i++) r.d[i] = (int32_t)((uint32_t)(d->w[2*i] * s->w[2*i]) + (uint32_t)(d->w[2*i+1] * s->w[2*i+1])); break;  // pmaddwd
    case 3: for (int i = 0; i < 8; i++) r.w[i] = sat16(d->b[2*i] * s->sb[2*i] + d->b[2*i+1] * s->sb[2*i+1]); break;  // pmaddubsw
    case 4: for (int i = 0; i < 8; i++) { r.sb[i] = sat8s(d->w[i]); r.sb[8+i] = sat8s(s->w[i]); } break;         // packsswb
    case 5: for (int i = 0; i < 8; i++) { r.b[i] = sat8u(d->w[i]); r.b[8+i] = sat8u(s->w[i]); } break;           // packuswb
    case 6: for (int i = 0; i < 4; i++) { r.w[i] = sat16(d->d[i] > 32767 ? 32767 : d->d[i] < -32768 ? -32768 : (int)d->d[i]); r.w[4+i] = sat16(s->d[i] > 32767 ? 32767 : s->d[i] < -32768 ? -32768 : (int)s->d[i]); } break;  // packssdw
    case 7: for (int i = 0; i < 4; i++) { r.uw[i] = sat16u(d->d[i]); r.uw[4+i] = sat16u(s->d[i]); } break;      // packusdw
    }
    *d = r;
}

#define RR(ins) __asm__ volatile("movdqa %0, %%xmm0\n movdqa %1, %%xmm1\n " ins " %%xmm1, %%xmm0\n movdqa %%xmm0, %0" : "+m"(*d) : "m"(*s) : "xmm0", "xmm1")
#define RM(ins) __asm__ volatile("movdqa %0, %%xmm2\n " ins " %1, %%xmm2\n movdqa %%xmm2, %0" : "+m"(*d) : "m"(*s) : "xmm2")
#define SS(ins) __asm__ volatile("movdqa %0, %%xmm3\n " ins " %%xmm3, %%xmm3\n movdqa %%xmm3, %0" : "+m"(*d) :: "xmm3")
static void run(int op, int form, V *d, const V *s) {
    switch (op * 3 + form) {
    case 0: RR("pmulhw"); break;    case 1: RM("pmulhw"); break;    case 2: SS("pmulhw"); break;
    case 3: RR("pmulhuw"); break;   case 4: RM("pmulhuw"); break;   case 5: SS("pmulhuw"); break;
    case 6: RR("pmaddwd"); break;   case 7: RM("pmaddwd"); break;   case 8: SS("pmaddwd"); break;
    case 9: RR("pmaddubsw"); break; case 10: RM("pmaddubsw"); break; case 11: SS("pmaddubsw"); break;
    case 12: RR("packsswb"); break; case 13: RM("packsswb"); break; case 14: SS("packsswb"); break;
    case 15: RR("packuswb"); break; case 16: RM("packuswb"); break; case 17: SS("packuswb"); break;
    case 18: RR("packssdw"); break; case 19: RM("packssdw"); break; case 20: SS("packssdw"); break;
    case 21: RR("packusdw"); break; case 22: RM("packusdw"); break; case 23: SS("packusdw"); break;
    }
}
int main(void) {
    static const char *names[] = {"pmulhw", "pmulhuw", "pmaddwd", "pmaddubsw", "packsswb", "packuswb", "packssdw", "packusdw"};
    int n = 0;
    for (int iter = 0; iter < 2000; iter++)
        for (int op = 0; op < 8; op++)
            for (int form = 0; form < 3; form++) {
                V a, b, want, got;
                for (int i = 0; i < 16; i++) { a.b[i] = rnd(); b.b[i] = rnd(); }
                if (iter & 1) for (int i = 0; i < 8; i++) { a.w[i] = (int16_t)(rnd() % 700) - 350; b.w[i] = (int16_t)(rnd() % 700) - 350; }
                want = a; ref(op, &want, form == 2 ? &a : &b);
                got = a; run(op, form, &got, &b);
                if (memcmp(&want, &got, 16)) { printf("packmul FAIL %s form %d iter %d\n", names[op], form, iter); return 1; }
                n++;
            }
    printf("packmul ok %d\n", n);
    return 0;
}
