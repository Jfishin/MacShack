// An Intel game's own Steam API under AArchX, the way a Rosetta game on an Apple silicon Mac runs it: the game's x86_64
// libsteam_api loads the x86_64 slice of Valve's universal steamclient.dylib in the game's process, which talks to the
// running (arm64) Steam over Mach, POSIX shared memory and semaphores. No game code; prints no account details, only a
// hash to compare runs (Rosetta, ocerz).
// clang -arch x86_64 check_steam_api.c -o /tmp/s
// Valve's x86_64 steamclient alone (no Steam running): ./ocerz -native /tmp/s -client "<Steam>/Contents/MacOS/steamclient.dylib"
//   expect `steamclient ok`
// A game's Steam API (Steam running; 480 is Spacewar, free to everyone; Steam shows it as played while this runs):
//   SteamAppId=480 arch -x86_64 /tmp/s "<Game>.app/.../libsteam_api.dylib"   (Rosetta, the reference)
//   SteamAppId=480 ./ocerz -native /tmp/s "<Game>.app/.../libsteam_api.dylib"   expect `steam api ok` and Rosetta's hash
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void *sym(void *h, const char *name) {
    void *f = dlsym(h, name);
    if (!f) printf("missing %s\n", name);
    return f;
}

// The newest accessor this SDK has (SteamAPI_SteamUser_v021 in one, v023 in another).
static void *accessor(void *h, const char *stem) {
    char name[96];
    for (int v = 40; v > 0; v--) {
        snprintf(name, sizeof name, "SteamAPI_%s_v%03d", stem, v);
        void *(*f)(void) = (void *(*)(void))dlsym(h, name);
        if (f) return f();
    }
    printf("no SteamAPI_%s_v* accessor\n", stem);
    return NULL;
}

static uint64_t fnv(uint64_t h, const void *p, size_t n) {
    for (size_t i = 0; i < n; i++) h = (h ^ ((const uint8_t *)p)[i]) * 0x100000001b3ull;
    return h;
}

static int client(const char *path) {
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("steamclient FAIL: %s\n", dlerror()); return 1; }
    void *(*create)(const char *, int *) = (void *(*)(const char *, int *))sym(h, "CreateInterface");
    int rc = -1;
    void *c = create ? create("SteamClient020", &rc) : NULL;
    if (!c) { printf("steamclient FAIL: no SteamClient020 (%d)\n", rc); return 1; }
    int (*createPipe)(void *) = (*(int (***)(void *))c)[0];   // ISteamClient::CreateSteamPipe, 0 without a Steam
    printf("steamclient ok: SteamClient020 %p, CreateSteamPipe %d\n", c, createPipe(c));
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "-client")) return client(argv[2]);
    if (argc != 2) { printf("usage: %s <libsteam_api.dylib> | -client <steamclient.dylib>\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("steam api FAIL: %s\n", dlerror()); return 1; }
    _Bool (*running)(void) = (_Bool (*)(void))sym(h, "SteamAPI_IsSteamRunning");
    _Bool (*init)(void) = (_Bool (*)(void))dlsym(h, "SteamAPI_Init");
    int (*initFlat)(char *) = (int (*)(char *))dlsym(h, "SteamAPI_InitFlat");   // SDK 1.58+: SteamAPI_Init is inline
    if (!running || (!init && !initFlat)) { printf("steam api FAIL: no SteamAPI_Init or SteamAPI_InitFlat\n"); return 1; }
    printf("SteamAPI_IsSteamRunning: %d\n", running());
    char message[1024] = "";
    if (init ? !init() : initFlat(message) != 0) { printf("steam api FAIL: init: %s\n", message); return 1; }
    void *user = accessor(h, "SteamUser"), *friends = accessor(h, "SteamFriends"), *utils = accessor(h, "SteamUtils");
    _Bool (*loggedOn)(void *) = (_Bool (*)(void *))sym(h, "SteamAPI_ISteamUser_BLoggedOn");
    uint64_t (*steamID)(void *) = (uint64_t (*)(void *))sym(h, "SteamAPI_ISteamUser_GetSteamID");
    const char *(*persona)(void *) = (const char *(*)(void *))sym(h, "SteamAPI_ISteamFriends_GetPersonaName");
    uint32_t (*appID)(void *) = (uint32_t (*)(void *))sym(h, "SteamAPI_ISteamUtils_GetAppID");
    void (*runCallbacks)(void) = (void (*)(void))sym(h, "SteamAPI_RunCallbacks");
    void (*shutdown)(void) = (void (*)(void))sym(h, "SteamAPI_Shutdown");
    if (!user || !friends || !utils || !loggedOn || !steamID || !persona || !appID || !runCallbacks || !shutdown) return 1;
    uint64_t id = steamID(user);
    const char *name = persona(friends);
    for (int i = 0; i < 10; i++) runCallbacks();
    int individual = id >> 56 == 1 && (id >> 52 & 0xf) == 1;   // public universe, individual account
    int ok = individual && name && *name;   // before shutdown: the name lives in steamclient's memory
    printf("logged on %d, individual account %d, persona name %zu bytes, app %u, hash %016llx\n", loggedOn(user),
           individual, name ? strlen(name) : 0, appID(utils), (unsigned long long)fnv(fnv(0xcbf29ce484222325ull, &id, sizeof id), name, name ? strlen(name) : 0));
    shutdown();
    printf(ok ? "steam api ok\n" : "steam api FAIL: no account\n");
    return !ok;
}
