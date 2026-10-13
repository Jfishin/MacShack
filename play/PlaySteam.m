#import "PlaySteam.h"
#import "ShackHooks.h"
#import "ShackPlay.h"
#import "ShackTranslated.h"
#import "vendor/fishhook.h"
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>

// MacShack Play's Steam client (the first step toward the Steam API in Windows games, lsteamclient): Valve's macOS
// steamclient, the game set MacShack prepared and signed for Play into the App Group's SteamClient folder (host/ShackSteamProbe.m ShackSteamPreparePlayFiles), loaded
// as a game's Steam API loads it and called through its interfaces, as Proton's lsteamclient will for a Windows game.
// It reaches MacShack's Steam over the game pipe, TCP 127.0.0.1:57343 (steamclient's name table maps Steam3Master
// there), which works between apps; ipcserver's Mach service (com.valvesoftware.steam.ipctool, the bookkeeper of Steam's
// named semaphores and shared memory) is MacShack's, its port from the bridge. Steam's images in this process see it as
// the stand-in pid MacShack's Steam knows (ShackPlaySteamPid).

static pid_t gPid = ShackPlaySteamPid;   // what MacShack's Steam knows this process as (a Mac game: its stand-in pid)
static pid_t steamPid(void) { return gPid; }
static void rebindSteamImage(const struct mach_header *h, intptr_t slide) {   // before the image's initializers
    Dl_info info;
    const char *slash = dladdr(h, &info) && info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
    if (!slash) return;
    for (const char *const *n = (const char *const[]){"steamclient_g.dylib", "steamclient.dylib", "libtier0_g.dylib", "libvstdlib_g.dylib", "libaudig.dylib", NULL}; *n; n++)
        if (!strcmp(slash + 1, *n))
            rebind_symbols_image((void *)h, slide, (struct rebinding[]){{"getpid", steamPid, NULL}, {"ThreadGetCurrentProcessId", steamPid, NULL}}, 2);
}

#define VCALL(object, slot, type) ((type)(*(void ***)(object))[slot])   // a C++ virtual call (this first)
#define SAY(...) say([NSString stringWithFormat:__VA_ARGS__])

NSString *PlaySteamPrepare(NSURL *group, mach_port_t ipc, NSString **error) {
    // libShackSteamClient (embedded in Play) has the port before steamclient's first look-up, so no ipcserver starts here.
    void *shim = dlopen("@rpath/libShackSteamClient.dylib", RTLD_NOW | RTLD_GLOBAL);
    void (*provide)(const char *, mach_port_t) = shim ? dlsym(shim, "ShackSteamClientProvideService") : NULL;
    if (!provide) { *error = [NSString stringWithFormat:@"libShackSteamClient: %s", shim ? "no ShackSteamClientProvideService" : dlerror()]; return nil; }
    if (!MACH_PORT_VALID(ipc)) { *error = @"no ipcserver port from MacShack (is Steam running there?)"; return nil; }
    provide("com.valvesoftware.steam.ipctool", ipc);
    // A fresh copy in Play's own container each run (new inodes), the layout kept: tier0 -> crashhandler -> Breakpad.
    // Earlier runs' copies go first (each is a full copy and Play runs one program per process, so none is in use).
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = NSTemporaryDirectory();
    for (NSString *name in [fm contentsOfDirectoryAtPath:tmp error:NULL])
        if ([name hasPrefix:@"steam-"]) [fm removeItemAtPath:[tmp stringByAppendingPathComponent:name] error:NULL];
    NSString *dir = [tmp stringByAppendingPathComponent:[@"steam-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    if (![NSFileManager.defaultManager copyItemAtPath:[group.path stringByAppendingPathComponent:@"SteamClient"] toPath:dir error:&copyError]) {
        *error = [@"copying Play's Steam images: " stringByAppendingString:copyError.localizedDescription];
        return nil;
    }
    NSString *macos = [dir stringByAppendingPathComponent:@"Contents/MacOS"];
    // lsteamclient's unix half loads $STEAM_COMPAT_CLIENT_INSTALL_PATH/steamclient.dylib: the game set under that name.
    symlink("steamclient_g.dylib", [macos stringByAppendingPathComponent:@"steamclient.dylib"].fileSystemRepresentation);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _dyld_register_func_for_add_image(rebindSteamImage); });
    return macos;
}

NSString *PlaySteamProbe(NSURL *group, mach_port_t ipc, uint32_t appID, unsigned seconds, void (^say)(NSString *)) {
    NSString *error = nil, *macos = PlaySteamPrepare(group, ipc, &error);
    if (!macos) return [@"FAIL: " stringByAppendingString:error];
    char app[16];
    snprintf(app, sizeof app, "%u", appID);
    setenv("SteamAppId", app, 1);   // what Steam gives a game it starts; steamclient reads it
    setenv("SteamGameId", app, 1);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    void *steamclient = dlopen([macos stringByAppendingPathComponent:@"steamclient_g.dylib"].fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!steamclient) return [NSString stringWithFormat:@"FAIL: dlopen steamclient_g: %s", dlerror()];
    SAY(@"steamclient loaded in %.2f s (getpid answers %d)", CFAbsoluteTimeGetCurrent() - t0, ShackPlaySteamPid);
    void *(*create)(const char *, int *) = dlsym(steamclient, "CreateInterface");
    int rc = 0;
    void *client = create ? create("SteamClient020", &rc) : NULL;
    SAY(@"CreateInterface(SteamClient020): %p (rc %d)", client, rc);
    if (!client) return @"FAIL: no SteamClient020";

    t0 = CFAbsoluteTimeGetCurrent();
    int32_t pipe = VCALL(client, 0, int32_t (*)(void *))(client);   // CreateSteamPipe: the TCP game pipe to Steam3Master
    SAY(@"CreateSteamPipe: %d in %.2f s", pipe, CFAbsoluteTimeGetCurrent() - t0);
    if (!pipe) return @"FAIL: CreateSteamPipe returned 0 (MacShack's Steam not reached)";
    int32_t user = VCALL(client, 2, int32_t (*)(void *, int32_t))(client, pipe);   // ConnectToGlobalUser
    SAY(@"ConnectToGlobalUser: %d", user);
    if (!user) {
        VCALL(client, 1, bool (*)(void *, int32_t))(client, pipe);
        return @"FAIL: ConnectToGlobalUser returned 0 (pipe up, no user)";
    }
    void *steamUser = VCALL(client, 5, void *(*)(void *, int32_t, int32_t, const char *))(client, user, pipe, "SteamUser023");
    void *friends = VCALL(client, 8, void *(*)(void *, int32_t, int32_t, const char *))(client, user, pipe, "SteamFriends018");
    void *utils = VCALL(client, 9, void *(*)(void *, int32_t, const char *))(client, pipe, "SteamUtils010");
    BOOL loggedOn = steamUser && VCALL(steamUser, 1, bool (*)(void *))(steamUser);
    uint64_t steamID = steamUser ? VCALL(steamUser, 2, uint64_t (*)(void *))(steamUser) : 0;   // CSteamID, in x0
    const char *persona = friends ? VCALL(friends, 0, const char *(*)(void *))(friends) : NULL;
    uint32_t serverTime = utils ? VCALL(utils, 3, uint32_t (*)(void *))(utils) : 0;
    const char *country = utils ? VCALL(utils, 4, const char *(*)(void *))(utils) : NULL;
    uint32_t steamApp = utils ? VCALL(utils, 9, uint32_t (*)(void *))(utils) : 0;   // slot 7 is the private GetCSERIPPort
    SAY(@"SteamUser023 %p: BLoggedOn %d, SteamID %llu (universe %llu, type %llu); SteamFriends018 %p: persona '%s'",
        steamUser, loggedOn, steamID, steamID >> 56, (steamID >> 52) & 0xF, friends, persona ?: "?");
    SAY(@"SteamUtils010 %p: server time %u (%+lld s from this clock), IP country %s, app id %u", utils, serverTime,
        serverTime ? (long long)serverTime - (long long)time(NULL) : 0, country ?: "?", steamApp);
    for (unsigned s = 5; s <= seconds; s += 5) {   // Steam shows the app running meanwhile
        sleep(5);
        SAY(@"held %u s: BLoggedOn %d", s, steamUser && VCALL(steamUser, 1, bool (*)(void *))(steamUser));
    }
    VCALL(client, 4, void (*)(void *, int32_t, int32_t))(client, pipe, user);   // ReleaseUser
    BOOL released = VCALL(client, 1, bool (*)(void *, int32_t))(client, pipe);   // BReleaseSteamPipe
    SAY(@"user and pipe released (%d)", released);
    return loggedOn && steamID && steamApp == appID ? [NSString stringWithFormat:@"PASS: logged on to MacShack's Steam from Play as app %u", appID]
                                                    : @"PARTIAL: connected, but not every answer is right (above)";
}

// A Mac game's own Steam API in Play, as MacShack gives one in its process (ShackSteamClient.m gameImageAdded): Valve's
// steamclient is not signed for this app, so the game's libsteam_api gets Play's signed copy; Steam's ipcserver comes
// from libShackSteamClient (its port from MacShack); libsteam_api and the steamclient set see the stand-in pid.
static char gGameCode[PATH_MAX];
static NSString *gSteamMacOS;
static kern_return_t (*gShimLookUp)(mach_port_t, const char *, mach_port_t *);
static void *(*gameOrigDlopen)(const char *, int);   // the image's dlopen as it loaded (ShackHooks')
static void *gameDlopen(const char *path, int mode) {
    const char *slash = path ? strrchr(path, '/') : NULL;
    if (!slash || strcmp(slash + 1, "steamclient.dylib")) return gameOrigDlopen(path, mode);
    if (!gSteamMacOS) { NSLog(@"[MacShack Play] the game's Steam API: no signed steamclient, the game runs without Steam"); return NULL; }
    void *handle = gameOrigDlopen([gSteamMacOS stringByAppendingPathComponent:@"steamclient_g.dylib"].fileSystemRepresentation, mode);
    NSLog(@"[MacShack Play] the game's Steam API: %s", handle ? "Play's steamclient_g" : dlerror());
    return handle;
}
static int (*realSteamInit)(const char *, char *);
static int gameSteamInit(const char *versions, char *message) {   // ESteamAPIInitResult: 0 OK, 1 failed, 2 no Steam, 3 versions
    char mine[1024] = "";
    int result = realSteamInit(versions, message ?: mine);
    NSLog(@"[MacShack Play] the game's SteamAPI_Init: %d %s", result, message ?: mine);
    return result;
}
// Valve's libsteam_api checks Steam's process (MacShack's, the pid ipcserver gives) with kill(pid, 0), which iOS refuses
// between apps ("steam found, but process is dead"): Steam is alive while MacShack's ipcserver port is.
static mach_port_t gIPC;
static int gameKill(pid_t pid, int sig) {
    int result = kill(pid, sig);
    if (!result || sig || pid == getpid()) return result;
    int error = errno;
    mach_port_type_t type = 0;
    BOOL alive = MACH_PORT_VALID(gIPC) && mach_port_type(mach_task_self(), gIPC, &type) == KERN_SUCCESS && !(type & MACH_PORT_TYPE_DEAD_NAME);
    static _Atomic int said = -1;   // logged when the answer changes: libsteam_api asks many times a second
    if (atomic_exchange(&said, alive) != alive)
        NSLog(@"[MacShack Play] the game's Steam API asks if Steam (pid %d) runs, errno %d: %s", pid, error, alive ? "yes, its ipcserver is there" : "no");
    if (alive) return 0;
    errno = error;
    return -1;
}
static void rebindGameImage(const struct mach_header *h, intptr_t slide) {
    Dl_info info;
    char real[PATH_MAX];
    size_t n = strlen(gGameCode);
    if (!n || !dladdr(h, &info) || !info.dli_fname || !realpath(info.dli_fname, real) || strncmp(real, gGameCode, n) || real[n] != '/') return;
    struct rebinding r[5] = {{"dlopen", gameDlopen, (void **)&gameOrigDlopen}, {"SteamInternal_SteamAPI_Init", gameSteamInit, (void **)&realSteamInit}};
    size_t count = 2;
    if (gShimLookUp) r[count++] = (struct rebinding){"bootstrap_look_up", gShimLookUp, NULL};
    if (!strcmp(strrchr(real, '/'), "/libsteam_api.dylib")) {
        r[count++] = (struct rebinding){"getpid", steamPid, NULL};
        r[count++] = (struct rebinding){"kill", gameKill, NULL};
    }
    rebind_symbols_image((void *)h, slide, r, count);
}

NSString *PlaySteamForGame(NSURL *group, mach_port_t ipc, NSString *codeRoot, pid_t pid) {
    NSString *error = nil, *macos = PlaySteamPrepare(group, ipc, &error);
    void *shim = macos ? dlopen("@rpath/libShackSteamClient.dylib", RTLD_NOW | RTLD_GLOBAL) : NULL;
    gShimLookUp = shim ? dlsym(shim, "bootstrap_look_up") : NULL;
    if (!realpath(codeRoot.fileSystemRepresentation, gGameCode)) return @"Steam for the game: FAILED: no code root";
    gPid = pid;
    gIPC = ipc;
    gSteamMacOS = gShimLookUp ? macos : nil;   // nil: Valve's unsigned steamclient is never tried, SteamAPI_Init fails as without Steam
    _dyld_register_func_for_add_image(rebindGameImage);   // after the game's hooks, before its images load
    if (!gSteamMacOS) return [@"Steam for the game: FAILED (it runs without Steam): " stringByAppendingString:error ?: @"no bootstrap_look_up in libShackSteamClient"];
    return [NSString stringWithFormat:@"Steam for the game: Play's steamclient in %@, pid %d", macos, pid];
}

// An Intel game's own Steam API (AArchX): its x86 libsteam_api loads Valve's x86 steamclient from Steam's folder (the
// path MacShack's Steam gives, reached through the hooks' moved-container rule), translated like the game; it gets the
// stand-in pid, Steam alive while MacShack's ipcserver port is, and libShackSteamClient's in-process IPC (the port from
// MacShack). Call before the game's main.
static void *gTranslatedShim;
static void *translatedSymbol(const char *name) {
    if (!strcmp(name, "getpid")) return (void *)steamPid;
    if (!strcmp(name, "kill")) return (void *)gameKill;
    return ShackTranslatedSteamSymbol(gTranslatedShim, name);
}
NSString *PlaySteamForTranslatedGame(mach_port_t ipc, pid_t pid) {
    gTranslatedShim = dlopen("@rpath/libShackSteamClient.dylib", RTLD_NOW | RTLD_GLOBAL);
    void (*provide)(const char *, mach_port_t) = gTranslatedShim ? dlsym(gTranslatedShim, "ShackSteamClientProvideService") : NULL;
    if (!provide || !MACH_PORT_VALID(ipc) || !ShackTranslatedSteamUse(gTranslatedShim))
        return @"Steam for the Intel game: FAILED (no libShackSteamClient or no ipcserver port): it runs without Steam";
    provide("com.valvesoftware.steam.ipctool", ipc);
    gPid = pid;
    gIPC = ipc;
    ShackHooksSetGuestSymbolAnswer(translatedSymbol);
    // AArchX answers the game's kill itself (its handler calls libOcerz's own import), past the symbol lookup: libsteam_api's
    // check that Steam runs (kill(pid, 0) on MacShack's pid) gets Play's answer there.
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "/libOcerz.dylib"))
            rebind_symbols_image((void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), (struct rebinding[]){{"kill", gameKill, NULL}}, 1);
    return [NSString stringWithFormat:@"Steam for the Intel game: Valve's x86 steamclient, pid %d", pid];
}
