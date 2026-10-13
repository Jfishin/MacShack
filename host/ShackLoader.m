#import "ShackLoader.h"
#import "ShackSteamPlay.h"
#import "ShackPlay.h"
#import "ShackSteamClient.h"
#import "ShackSteamProbe.h"
#import "ShackHooks.h"
#import "ShackWatch.h"
#import "ShackJIT.h"
#import "ShackMetal.h"
#import "ShackInstaller.h"
#import "ShackPrep.h"
#import "ShackGameLaunch.h"
#import "ShackTranslated.h"
#import <dlfcn.h>
#import <pthread.h>
#import <sys/mman.h>
#import <unistd.h>

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
            BOOL started = translate ? ShackStartTranslated(exePath, args, &e) : ShackStartGuest(codePath, exePath, args, nil, NULL, &e);
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
