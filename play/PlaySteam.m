#import "PlaySteam.h"
#import "ShackPlay.h"
#import "vendor/fishhook.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

// MacShack Play's Steam client (the first step toward the Steam API in Windows games, lsteamclient): Valve's macOS
// steamclient, the game set MacShack prepared and signed for Play into the App Group's SteamClient folder (host/ShackSteamProbe.m ShackSteamPreparePlayFiles), loaded
// as a game's Steam API loads it and called through its interfaces, as Proton's lsteamclient will for a Windows game.
// It reaches MacShack's Steam over the game pipe, TCP 127.0.0.1:57343 (steamclient's name table maps Steam3Master
// there), which works between apps; ipcserver's Mach service (com.valvesoftware.steam.ipctool, the bookkeeper of Steam's
// named semaphores and shared memory) is MacShack's, its port from the bridge. Steam's images in this process see it as
// the stand-in pid MacShack's Steam knows (ShackPlaySteamPid).

static pid_t steamPid(void) { return ShackPlaySteamPid; }
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
