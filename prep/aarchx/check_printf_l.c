// The guest libc++ formats and parses numbers with asprintf_l and sscanf_l (a long float through an ostream, a pointer
// through an istream); both used to be stubs that ended the game (BioShock, 2026-09-29, mid-gameplay). A double longer
// than libc++'s 30-byte buffer takes the asprintf_l path. %L (x87 long double) stays refused: it does not cross to arm64.
// clang -arch x86_64 check_printf_l.c -o /tmp/c && ./ocerz -native /tmp/c   # printf_l ok
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xlocale.h>

int main(void) {
    locale_t c = newlocale(LC_ALL_MASK, "C", NULL);
    char *s = NULL;
    int n = asprintf_l(&s, c, "%.3f|%s|%d|%.1f", 2.5, "x", 42, 1e30);
    int a = 0; double d = 0; char w[8] = {0};
    int m = sscanf_l("7 1.25 hi", c, "%d %lf %7s", &a, &d, w);
    if (n != 44 || !s || strcmp(s, "2.500|x|42|1000000000000000019884624838656.0") || m != 3 || a != 7 || d != 1.25 || strcmp(w, "hi")) {
        printf("printf_l FAIL: asprintf_l %d '%s', sscanf_l %d (%d %g '%s')\n", n, s ? s : "(null)", m, a, d, w);
        return 1;
    }
    free(s);
    freelocale(c);
    printf("printf_l ok\n");
    return 0;
}
