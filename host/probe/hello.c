#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/dyld.h>
int main(int argc, char **argv) {
    char exe[1024]; uint32_t n = sizeof exe; _NSGetExecutablePath(exe, &n);
    const char *home = getenv("HOME");
    char path[1200]; snprintf(path, sizeof path, "%s/hello.txt", home ? home : "/tmp");
    FILE *f = fopen(path, "w");
    if (!f) return 2;
    fprintf(f, "argv0=%s\nexe=%s\nhome=%s\n", argv[0], exe, home ? home : "(null)");
    fclose(f);
    return 0;
}
