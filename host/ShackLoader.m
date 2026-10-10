#import "ShackLoader.h"
#import "ShackSteamPlay.h"
#import "ShackPlay.h"
#import "ShackSteamClient.h"
#import "ShackSteamProbe.h"
#import "ShackHooks.h"
#import "ShackWatch.h"
#import "ShackJIT.h"
#import "ShackMetal.h"
#import "ShackSwap.h"
#import "ShackInstaller.h"
#import "ShackPrep.h"
#import "ShackGameLaunch.h"
#import <dlfcn.h>
#import <locale.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <sys/mman.h>
#import <unistd.h>
#import <crt_externs.h>

static NSError *err(NSString *msg) { return [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

static NSString *codeRootForApp(NSString *appPath, NSError **error) {
    NSError *failure = nil;
    NSString *prepared = [ShackInstaller preparedCodeRootForAppPath:appPath error:&failure];
    if (prepared) return prepared;
    if (failure) { if (error) *error = failure; return nil; }
    NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *embedded = [NSBundle.mainBundle.bundlePath stringByAppendingFormat:@"/Frameworks/Guests/%@", name];
    if ([NSFileManager.defaultManager fileExistsAtPath:embedded]) return embedded;
    if (error) *error = err(@"This game needs preparation. Use Prepare again in its menu, or copy an unmodified .app into MacShack/Staging.");
    return nil;
}

static void reportLaunchFailure(NSString *message) {
    NSLog(@"[MacShack] %@", message);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"ShackGuestLaunchFailed" object:nil
                                                       userInfo:@{@"message": message}];
    });
}

// Intel games: AArchX (vendor/AArchX, libOcerz.dylib; prep/aarchx/README.md) translates the original x86_64
// executable from Documents/Games. Its bridged calls open the same libraries prep maps arm64 games to.
int ocerz_main(int argc, char **argv);
void ocerz_bridge_set_host_open(void *(*open)(const char *install_name));
void ocerz_bridge_set_host_symbol(void *(*sym)(const char *host_sym));

static void *ocerzHostOpen(const char *installName) {
    NSString *lib = [ShackPrep hostLibraryForInstallName:@(installName)];
    return lib ? dlopen(lib.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL) : NULL;   // @rpath: this image's rpaths
}

static NSString *gHostBundlePath;   // MacShack.app, before ShackHooksInstall makes mainBundle the game
__attribute__((constructor)) static void captureHostBundlePath(void) { gHostBundlePath = NSBundle.mainBundle.bundlePath; }

// Runs an Intel game's main on this thread under AArchX and returns its status. Needs SHACK_JIT_POOL
// (ShackJITPoolSetup): AArchX's interpreter alone is >10x too slow for a game.
int ShackRunTranslated(NSString *exePath, NSArray<NSString *> *args) {
    const char *pool = getenv("SHACK_JIT_POOL");
    if (!pool) { NSLog(@"[MacShack] x86_64 translation needs the JIT pool, and none was prepared"); return 126; }
    setenv("OCERZ_JIT_POOL", pool, 1);
    setenv("OCERZ_STUB_MISSING", "1", 0);   // an import no bridge covers becomes a logged stub, not a refused launch (AArchX dyld.c)
    // The arena must fit the address space left, with room beside it: iOS gives ~64 GB, and beside the Steam client
    // Chromium already holds ~47 of it. A 16 GB arena that just fit (Cuphead from Steam,
    // 10-04) left too little for the game's next thread stack (EAGAIN, abort) and Chromium's next IOSurface.
    // ponytail: the largest of 16/8/4 GB that maps with 4 GB more free beside it (counted in 1 GB pieces); raise the 4
    // if the log shows a game's host side running out anyway.
    if (!getenv("OCERZ_ARENA_GB")) {
        int gb = 16, freeGB = 0;
        for (;; gb /= 2) {
            void *arena = mmap(NULL, (size_t)gb << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0), *rest[64];
            freeGB = 0;
            if (arena != MAP_FAILED) {
                while (freeGB < 64 && (rest[freeGB] = mmap(NULL, 1ull << 30, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)) != MAP_FAILED) freeGB++;
                for (int i = 0; i < freeGB; i++) munmap(rest[i], 1ull << 30);
                munmap(arena, (size_t)gb << 30);
            }
            if ((arena != MAP_FAILED && freeGB >= 4) || gb == 4) break;
        }
        setenv("OCERZ_ARENA_GB", [NSString stringWithFormat:@"%d", gb].UTF8String, 1);
        NSLog(@"[MacShack] AArchX arena: %d GB, %d GB more free beside it", gb, freeGB);
    }
    setenv("OCERZ_APIDB", [gHostBundlePath stringByAppendingPathComponent:@"AArchX/apis"].fileSystemRepresentation, 1);
    setenv("OCERZ_GUEST_ROOT", [gHostBundlePath stringByAppendingPathComponent:@"AArchX/guest"].fileSystemRepresentation, 1);
    // i386 games (m32, picked by AArchX's main from the Mach-O): their API databases are OCERZ_APIDB + "32"; the guest
    // GNU C++ runtime lives beside the x86_64 one
    setenv("OCERZ_GUEST32_ROOT", [gHostBundlePath stringByAppendingPathComponent:@"AArchX/guest32"].fileSystemRepresentation, 1);
    ocerz_bridge_set_host_open(ocerzHostOpen);
    ocerz_bridge_set_host_symbol(ShackHookForGuestSymbol);   // game bundle identity, case-insensitive paths
    int argc = 3 + (int)args.count;
    char **argv = calloc((size_t)argc + 1, sizeof *argv);   // lives for the process
    argv[0] = strdup("ocerz"); argv[1] = strdup("-native"); argv[2] = strdup(exePath.fileSystemRepresentation);
    for (NSUInteger i = 0; i < args.count; i++) argv[3 + i] = strdup(args[i].UTF8String);
    return ocerz_main(argc, argv);   // runs the guest's main on this thread, as ShackStartGuest does
}

static void *translatedThread(void *arg) {
    NSArray *exeAndArgs = CFBridgingRelease(arg);
    pthread_setname_np("guest-main");
    int rc = ShackRunTranslated(exeAndArgs[0], exeAndArgs[1]);
    NSLog(@"[MacShack] translated guest returned %d", rc);
    ShackGuestEnded(rc);
    return NULL;
}

static BOOL startTranslated(NSString *exePath, NSArray<NSString *> *args, NSError **error) {
    if (!getenv("SHACK_JIT_POOL")) { if (error) *error = err(@"x86_64 translation needs the JIT pool, and none was prepared."); return NO; }
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64 << 20);
    pthread_t th; int e = pthread_create(&th, &at, translatedThread, (void *)CFBridgingRetain(@[exePath, args]));
    if (e) { if (error) *error = err([NSString stringWithFormat:@"pthread_create: %d", e]); return NO; }
    return YES;
}

// A game's frame cap and render scale: its own (`fpsCap.<Name>`, `renderScale.<Name>`: the game tile, the island menu;
// -1 / 0 = follow the default), else the defaults (`fpsCap`, `renderScale`: Settings, the Steam settings), else 60 fps
// (what Low Power Mode holds the panel to; uncapped native games ran the panel at 120 and heated the phone) and 2x
// (Tunic at Full Retina needed 10.4 ms of GPU a frame and fell to 30-40 under a 60 cap; 2x is 44% of the pixels and
// looks nearly the same at 460 ppi). x86 games: 60 even when the default is uncapped (translation already heats the
// phone; Hades uncapped reached "thermal serious").
int ShackGameFrameCap(NSString *name, BOOL translate) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id own = [d objectForKey:[@"fpsCap." stringByAppendingString:name]], fallback = [d objectForKey:@"fpsCap"];
    if (own && [own intValue] >= 0) return [own intValue];
    int cap = fallback ? [fallback intValue] : 60;
    return translate && cap == 0 ? 60 : cap;
}
double ShackGameRenderScale(NSString *name, BOOL translate) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    double own = [d doubleForKey:[@"renderScale." stringByAppendingString:name]], fallback = [d doubleForKey:@"renderScale"];
    return own > 0 ? own : fallback > 0 ? fallback : 2;
}
// The Steam client's own UI (Big Picture): `steamUI.fpsCap` (default 60) and `steamUI.renderScale` (default 2x: a third
// fewer pixels per side than the panel, still sharp for UI). Chromium draws a frame per display-link tick at this rate.
int ShackSteamUIFrameCap(void) {
    id cap = [NSUserDefaults.standardUserDefaults objectForKey:@"steamUI.fpsCap"];
    return cap ? [cap intValue] : 60;
}
double ShackSteamUIRenderScale(void) {
    double scale = [NSUserDefaults.standardUserDefaults doubleForKey:@"steamUI.renderScale"];
    return scale > 0 ? scale : 2;
}

@implementation ShackLoader

+ (BOOL)validateAppAtPath:(NSString *)appPath error:(NSError **)error {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"];
    if (![exe isKindOfClass:NSString.class] || !exe.length || ![exe.lastPathComponent isEqualToString:exe] ||
        [exe isEqualToString:@"."] || [exe isEqualToString:@".."]) {
        if (error) *error = err(@"Invalid CFBundleExecutable in the game's Info.plist."); return NO;
    }
    NSString *root = codeRootForApp(appPath, error);
    if (!root) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingFormat:@"/Contents/MacOS/%@", exe]]) {
        if (error) *error = err(@"Prepared executable is missing. Prepare this game again."); return NO;
    }
    return YES;
}


+ (NSNumber *)runGuestMainAtPath:(NSString *)exePath home:(NSString *)home argv0:(NSString *)argv0 error:(NSError **)error {
    setenv("HOME", home.fileSystemRepresentation, 1);
    int rc = -1;
    if (!ShackStartGuest(exePath, argv0, nil, dispatch_semaphore_create(0), &rc, error)) return nil;
    return @(rc);
}

+ (BOOL)launchAppAtPath:(NSString *)appPath error:(NSError **)error {
    appPath = appPath.stringByStandardizingPath;
    if (![self validateAppAtPath:appPath error:error]) return NO;
    NSString *codeRoot = codeRootForApp(appPath, error);
    if (!codeRoot) return NO;
    NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
    BOOL needsJIT = [ShackInstaller requiresJITAtAppPath:appPath];
    BOOL translate = [ShackInstaller translatesAtAppPath:appPath];
    // Frame cap and render scale (`-fpsCap.<Name> 30` or `-fpsCap 30` as launch arguments for devicectl runs); memory
    // tier `swapMB.<Name>`, else `swapMB`, else off (launch arguments arrive as strings).
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id ownSwap = [defaults objectForKey:[@"swapMB." stringByAppendingString:name]], anySwap = [defaults objectForKey:@"swapMB"];
    NSMutableDictionary *launch = [@{@"app": appPath, @"code": codeRoot,
        @"logs": [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"],
        @"argsFile": [appPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"args"], @"translate": @(translate),
        @"fpsCap": @(ShackGameFrameCap(name, translate)), @"renderScale": @(ShackGameRenderScale(name, translate)),
        @"swapMB": @(ownSwap ? [ownSwap integerValue] : anySwap ? [anySwap integerValue] : 0)} mutableCopy];
    NSString *displaySize = [defaults stringForKey:[@"displaySize." stringByAppendingString:name]];
    if (displaySize.length) launch[@"displaySize"] = displaySize;
    NSDictionary *ready = ShackGamePrepareProcess(launch, error);
    if (!ready) return NO;
    // Hooks are installed and point at this guest: a failed launch is terminal for this process.
    NSString *exePath = ready[@"exePath"], *codePath = ready[@"codePath"];
    NSArray *args = ready[@"args"];
    int jitMB = [ready[@"jitMB"] intValue];
    BOOL watch = [ready[@"watch"] boolValue];
    // Mono guest (Unity): the patched runtime needs one debugger-prepared RX pool with an RW alias before its
    // first code allocation. ponytail: keyed on the dylib's presence; the prepare costs one debugger round-trip
    // per 16 KB page (two per round trip for a debugger-allocated pool), so the default is 128 MB (512-1024 for x86), raise with --shack-jit-mb=N in the
    // .args if Mono logs exhaustion.
    if (needsJIT) {
        // Off the main thread: the JIT helper (or StikDebug) attaches meanwhile, and a main thread blocked through that
        // background transition is a watchdog kill. Errors from this path can only reach the game log.
        NSLog(@"[MacShack] Mono guest: waiting for the debugger to prepare a %d MB JIT pool", jitMB);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (!ShackJITPoolSetup((size_t)jitMB << 20)) {
                reportLaunchFailure(@"JIT setup failed: no debugger attached within 3 minutes. Keep the phone unlocked and LocalDevVPN connected (without a pairing file, tap Enable Script in StikDebug). Close and reopen MacShack to retry.");
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:@"ShackJITReady" object:nil];
            });
            ShackWatchStart(watch);
            NSError *e = nil;
            BOOL started = translate ? startTranslated(exePath, args, &e) : ShackStartGuest(codePath, exePath, args, nil, NULL, &e);
            if (!started) reportLaunchFailure([e.localizedDescription stringByAppendingString:@" Close and reopen MacShack to retry."]);
        });
        return YES;
    }
    ShackWatchStart(watch);
    if (ShackStartGuest(codePath, exePath, args, nil, NULL, error)) return YES;
    if (error && *error) *error = err([(*error).localizedDescription stringByAppendingString:@" (relaunch MacShack to retry)"]);
    return NO;
}

+ (BOOL)launchSteamClientWithArguments:(NSArray<NSString *> *)extra error:(NSError **)error {
    NSString *home = NSHomeDirectory();
    NSString *bundle = [home stringByAppendingPathComponent:@"Library/Application Support/Steam/Steam.AppBundle/Steam"].stringByStandardizingPath;
    NSString *code = [home stringByAppendingPathComponent:@"Library/Guests/SteamClient/Steam"];
    NSString *macos = [bundle stringByAppendingPathComponent:@"Contents/MacOS"];
    NSString *exePath = [macos stringByAppendingPathComponent:@"steam_osx"];
    NSString *codePath = [code stringByAppendingPathComponent:@"Contents/MacOS/steam_osx"];
    if (![NSFileManager.defaultManager fileExistsAtPath:codePath]) {
        if (error) *error = err(@"Steam is not set up. Tap Set up Steam, or Settings > Repair Steam."); return NO;
    }
    NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("HOME", home.fileSystemRepresentation, 1);   // Steam's root is ~/Library/Application Support/Steam, as on a Mac
    setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    // What Steam.app's bootstrapper hands steam_osx; without them steam_osx sets them and re-execs itself (no exec on iOS).
    setenv("STEAM_CLIENT_CONFIG_FILE", [macos stringByAppendingPathComponent:@"steam.cfg"].fileSystemRepresentation, 1);
    setenv("STEAM_APP_BUNDLE_PATH", bundle.fileSystemRepresentation, 1);
    chdir(macos.fileSystemRepresentation);
    ShackRedirectOutput([logs stringByAppendingPathComponent:@"steam_osx.log"]);
    NSLog(@"[MacShack] launching the Steam client: code=%@ data=%@", code, bundle);
    // Chromium appends to Steam's cef_log.txt across launches; a failure loop once grew it to GBs on the phone.
    NSString *steamLogs = [home stringByAppendingPathComponent:@"Library/Application Support/Steam/logs"];
    for (NSString *name in @[@"cef_log.txt", @"cef_log.previous.txt"]) {
        NSString *path = [steamLogs stringByAppendingPathComponent:name];
        if ([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize] > 50 << 20) {
            NSLog(@"[MacShack] %@ is over 50 MB: removed", name);
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
    // Steam Play only while Windows games are on (set up, and MacShack Play installed: Settings > Windows games); else
    // Steam stays stock and what an earlier setup added is taken out. Here, before steam_osx runs: it rewrites its VDF
    // files on exit.
    NSString *steamRoot = [home stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(ShackPlayHostBundleID())];
    BOOL steamPlay = ShackWindowsGamesOn();
    if (steamPlay) ShackSteamPlaySetup(steamRoot, group);
    else ShackSteamPlayRemove(steamRoot, group);
    ShackSteamPrepareHelperFiles(steamPlay);   // private images a newer MacShack added (steamclient_h, steamclient_g), steamclient as Steam Play wants it
    ShackHooksInstall(bundle, exePath, code);
    ShackSteamClientInstall(bundle, code);   // Steam Helper (Chromium) in-process when steam_osx starts it
    [NSClassFromString(@"NSScreen") valueForKey:@"mainScreen"];   // prime the shim's screen metrics on the main thread
    ShackAppKitSetRenderScale(ShackSteamUIRenderScale());
    ShackMetalSetFrameCap(ShackSteamUIFrameCap());
    // Steam's own updater, file repair and universal-binary relaunch all start other programs, which iOS cannot.
    // --shack-watch (MacShack's, not Steam's): every 10 s the stacks of Steam's threads into the log (ShackWatch).
    NSArray *args = [@[@"-noverifyfiles", @"-nobootstrapupdate", @"-skipinitialbootstrap", @"-norepairfiles", @"-noarchrestart"]
                     arrayByAddingObjectsFromArray:[extra filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != '--shack-watch'"]]];
    ShackWatchStart([extra containsObject:@"--shack-watch"]);
    NSLog(@"[MacShack] args %@", [args componentsJoinedByString:@" "]);
    return ShackStartGuest(codePath, exePath, args, nil, NULL, error);
}
@end
