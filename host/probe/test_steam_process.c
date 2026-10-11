// Mac check of libShackSteamClient's answers to Steam's popen (shims/SteamClient/SteamProcess.c): `ps` lists this
// process (Steam's Stop asks it first), lsof is answered, anything else is refused.
//   clang shims/SteamClient/SteamProcess.c host/probe/test_steam_process.c -o /tmp/t && /tmp/t
// expect `steam process ok`.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *read_all(FILE *f) {
    static char text[256];
    size_t n = f ? fread(text, 1, sizeof text - 1, f) : 0;
    text[n] = 0;
    return text;
}
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) {
    char me[32];
    snprintf(me, sizeof me, "%d 1\n", getpid());
    FILE *f = popen("/bin/ps -x -o pid=,ppid=", "r");
    CHECK(f && !strcmp(read_all(f), me));
    CHECK(pclose(f) == 0);
    f = popen("/usr/sbin/lsof -F up -i TCP@127.0.0.1:1", "r");
    CHECK(f && !strcmp(read_all(f), ""));   // no socket of ours on that port
    CHECK(pclose(f) == 0);
    errno = 0;
    CHECK(!popen("/bin/ls", "r") && errno == EPERM);
    puts("steam process ok");
    return 0;
}
