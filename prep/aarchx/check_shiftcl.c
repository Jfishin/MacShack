// Shifts by cl whose flags are read afterwards (BioShock's WebM bit reader: ~240 million per minute of video went to
// the interpreter). A zero count must leave the flags of the instruction before alone. Defined flags only: CF ZF SF PF,
// and OF when the count is 1. The checksum must match under Rosetta, `ocerz -native -no-jit` and `ocerz -native`.
// clang -arch x86_64 check_shiftcl.c -o /tmp/c && ./ocerz -native /tmp/c   # shiftcl ok ea85a0352a21c4f6
#include <stdint.h>
#include <stdio.h>

#define CF 0x1u
#define PF 0x4u
#define ZF 0x40u
#define SF 0x80u
#define OF 0x800u

static uint64_t mask_for(unsigned cnt) { return cnt == 0 ? (CF | PF | ZF | SF | OF) : cnt == 1 ? (CF | PF | ZF | SF | OF) : (CF | PF | ZF | SF); }

#define SHIFT64(OP)                                                                                                    \
    static uint64_t OP##64(uint64_t v, unsigned c, uint64_t pre, uint64_t *fl, uint8_t *z) {                           \
        uint64_t f; uint8_t cy;                                                                                        \
        __asm__ volatile("cmp %[pre], %[zero]\n\t" #OP "q %%cl, %[v]\n\tsetz %[z]\n\tsetc %[c]\n\tpushfq\n\tpopq %[f]"               \
                         : [v] "+r"(v), [f] "=r"(f), [z] "=r"(*z), [c] "=r"(cy)                                       \
                         : "c"(c), [pre] "r"(pre), [zero] "r"((uint64_t)0)                                              \
                         : "cc");                                                                                      \
        *fl = f; *z |= (uint8_t)(cy << 1);                                                                             \
        return v;                                                                                                      \
    }
#define SHIFT32(OP)                                                                                                    \
    static uint64_t OP##32(uint32_t v, unsigned c, uint64_t pre, uint64_t *fl, uint8_t *z) {                           \
        uint64_t f; uint8_t cy;                                                                                        \
        __asm__ volatile("cmp %[pre], %[zero]\n\t" #OP "l %%cl, %[v]\n\tsetz %[z]\n\tsetc %[c]\n\tpushfq\n\tpopq %[f]"               \
                         : [v] "+r"(v), [f] "=r"(f), [z] "=r"(*z), [c] "=r"(cy)                                       \
                         : "c"(c), [pre] "r"(pre), [zero] "r"((uint64_t)0)                                              \
                         : "cc");                                                                                      \
        *fl = f; *z |= (uint8_t)(cy << 1);                                                                             \
        return v;                                                                                                      \
    }
SHIFT64(shl) SHIFT64(shr) SHIFT64(sar) SHIFT32(shl) SHIFT32(shr) SHIFT32(sar)

int main(void) {
    uint64_t sum = 0, x = 0x9e3779b97f4a7c15ull;
    for (int round = 0; round < 3000; round++) {   // hot, so the JIT translates the shifts
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        uint64_t v = x, pre = (x >> 3) & 3;   // pre: the cmp before sets different flags each round
        for (unsigned c = 0; c < 64; c++) {
            uint64_t f; uint8_t z; uint64_t r;
            r = shl64(v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c)) ^ z;
            r = shr64(v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c)) ^ z;
            r = sar64(v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c)) ^ z;
            unsigned c32 = c & 31;
            r = shl32((uint32_t)v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c32)) ^ z;
            r = shr32((uint32_t)v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c32)) ^ z;
            r = sar32((uint32_t)v, c, pre, &f, &z); sum = sum * 1099511628211ull ^ r ^ (f & mask_for(c32)) ^ z;
        }
    }
    printf("shiftcl ok %016llx\n", (unsigned long long)sum);
    return 0;
}
