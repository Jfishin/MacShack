// check_sidegap.c: a compare with a memory operand, a flag-neutral gap that moves the compare's base, then jne
// (BioShock's hash loop). Fusing the compare after the gap reads the wrong element. Expect `sidegap ok <n>`.
#include <stdio.h>
#include <stdint.h>
int main(void) {
    static int64_t a[66];
    for (int i = 0; i < 66; i++) a[i] = (i * 37 % 11 == 4) ? -2 : i;
    long want = 0, got = 0;
    for (int k = 0; k < 63; k++) if (a[k + 1] == -2) want += k;
    want *= 20000;
    for (int rep = 0; rep < 20000; rep++) {
        int64_t *p = a;
        for (int k = 0; k < 63; k++) {
            long hit = 0;
            __asm__ volatile("xorl %%eax, %%eax\n\t"
                             "cmpq $-2, 8(%[p],%%rax,8)\n\t"
                             "leaq 8(%[p]), %[p]\n\t"
                             "jne 1f\n\t"
                             "movq $1, %[hit]\n"
                             "1:\n"
                             : [p] "+r"(p), [hit] "+r"(hit) : : "rax", "cc", "memory");
            got += hit * k;
        }
    }
    if (got == want) printf("sidegap ok %ld\n", got);
    else printf("sidegap BAD %ld want %ld\n", got, want);
    return 0;
}
