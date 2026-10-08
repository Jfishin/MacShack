// steamapi-test.exe [appid] [seconds] [steamclient64]: a Windows x64 program's view of Steam through lsteamclient, in MacShack Play
// (the check behind --play-steam-wine): the same calls as play/PlaySteam.m, made from Windows code under Madeira's
// Wine, so they go PE lsteamclient.dll -> unix lsteamclient.so -> Valve's macOS steamclient -> MacShack's Steam.
// Writes C:\steamapi-test.txt (Play appends it to its report). Built by windows-kit/helpers/build.sh.
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VCALL(object, slot, type) ((type)(*(void ***)(object))[slot])   // a C++ virtual call: this in rcx

static FILE *out;
#define SAY(...) do { fprintf(out, __VA_ARGS__); fputc('\n', out); fflush(out); } while (0)

int main(int argc, char **argv) {
    const char *app = argc > 1 ? argv[1] : "480";
    int seconds = argc > 2 ? atoi(argv[2]) : 30;
    if (!(out = fopen("C:\\steamapi-test.txt", "w"))) return 2;
    SetEnvironmentVariableA("SteamAppId", app);   // lsteamclient hands it to the native steamclient
    SetEnvironmentVariableA("SteamGameId", app);
    // With "steamclient64", as a game's steam_api64.dll does: Valve's steamclient64.dll from the prefix's Steam folder,
    // whose exports the ntdll detour (NotProton's) has pointed at lsteamclient's while it loaded.
    int viaValve = argc > 3 && !strcmp(argv[3], "steamclient64");
    const char *path = viaValve ? "C:\\Program Files (x86)\\Steam\\steamclient64.dll" : "lsteamclient.dll";
    HMODULE lib = viaValve ? LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH) : LoadLibraryA(path);
    SAY("LoadLibrary(%s): %p%s", path, (void *)lib, lib ? "" : " FAILED");
    if (viaValve && lib) {   // the detour's x64 jump (movabs rax, target; jmp rax) and where it goes
        const unsigned char *entry = (const unsigned char *)GetProcAddress(lib, "CreateInterface");
        HMODULE lsteam = GetModuleHandleA("lsteamclient.dll");
        void *target = entry && entry[0] == 0x48 && entry[1] == 0xB8 ? *(void *const *)(entry + 2) : NULL;
        void *real = lsteam ? (void *)GetProcAddress(lsteam, "CreateInterface") : NULL;
        SAY("steamclient64 CreateInterface %p: %s; lsteamclient %p, its CreateInterface %p", (const void *)entry,
            target ? (target == real ? "jumps to lsteamclient's (the ntdll detour ran)" : "jumps elsewhere") : "Valve's own code (no detour)",
            (void *)lsteam, real);
    }
    void *(*create)(const char *, int *) = lib ? (void *(*)(const char *, int *))GetProcAddress(lib, "CreateInterface") : NULL;
    int rc = 0;
    void *client = create ? create("SteamClient020", &rc) : NULL;
    SAY("CreateInterface(SteamClient020): %p (rc %d)", client, rc);
    if (!client) { SAY("FAIL: no SteamClient020 (native steamclient not loaded?)"); return 1; }
    DWORD t0 = GetTickCount();
    int32_t pipe = VCALL(client, 0, int32_t (*)(void *))(client);
    SAY("CreateSteamPipe: %d in %lu ms", pipe, GetTickCount() - t0);
    if (!pipe) { SAY("FAIL: CreateSteamPipe returned 0"); return 1; }
    int32_t user = VCALL(client, 2, int32_t (*)(void *, int32_t))(client, pipe);
    SAY("ConnectToGlobalUser: %d", user);
    if (!user) { SAY("FAIL: ConnectToGlobalUser returned 0"); return 1; }
    void *steamUser = VCALL(client, 5, void *(*)(void *, int32_t, int32_t, const char *))(client, user, pipe, "SteamUser023");
    void *friends = VCALL(client, 8, void *(*)(void *, int32_t, int32_t, const char *))(client, user, pipe, "SteamFriends018");
    void *utils = VCALL(client, 9, void *(*)(void *, int32_t, const char *))(client, pipe, "SteamUtils010");
    int loggedOn = steamUser ? VCALL(steamUser, 1, int8_t (*)(void *))(steamUser) : 0;
    uint64_t steamID = 0;   // CSteamID by value from a member function: MSVC returns it through a hidden pointer
    if (steamUser) VCALL(steamUser, 2, uint64_t *(*)(void *, uint64_t *))(steamUser, &steamID);
    const char *persona = friends ? VCALL(friends, 0, const char *(*)(void *))(friends) : NULL;
    uint32_t appID = utils ? VCALL(utils, 9, uint32_t (*)(void *))(utils) : 0;   // slot 7 is the private GetCSERIPPort
    uint32_t serverTime = utils ? VCALL(utils, 3, uint32_t (*)(void *))(utils) : 0;
    SAY("SteamUser023 %p: BLoggedOn %d, SteamID universe %llu type %llu (%s)", steamUser, loggedOn,
        (unsigned long long)(steamID >> 56), (unsigned long long)((steamID >> 52) & 0xF), steamID ? "set" : "none");
    SAY("SteamFriends018 %p: persona %s; SteamUtils010 %p: app id %u, server time %u", friends,
        persona && *persona ? "set" : "none", utils, appID, serverTime);
    for (int s = 5; s <= seconds; s += 5) {
        Sleep(5000);
        SAY("held %d s: BLoggedOn %d", s, steamUser ? VCALL(steamUser, 1, int8_t (*)(void *))(steamUser) : 0);
    }
    VCALL(client, 4, void (*)(void *, int32_t, int32_t))(client, pipe, user);   // ReleaseUser
    VCALL(client, 1, int8_t (*)(void *, int32_t))(client, pipe);   // BReleaseSteamPipe
    int pass = loggedOn && steamID && appID == (uint32_t)atoi(app);
    SAY("%s", pass ? "PASS: a Windows program is logged on to MacShack's Steam through lsteamclient" : "PARTIAL: see above");
    fclose(out);
    return pass ? 0 : 1;
}
