#import "ShackLoader.h"
#import "ShackSteamPlay.h"
#import "ShackPlay.h"
#import "ShackSteamClient.h"
#import "ShackSteamProbe.h"
#import "ShackHooks.h"
#import "ShackWatch.h"
#import "ShackMetal.h"
#import "ShackGameLaunch.h"
#import <unistd.h>

static NSError *err(NSString *msg) { return [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

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

+ (NSNumber *)runGuestMainAtPath:(NSString *)exePath home:(NSString *)home argv0:(NSString *)argv0 error:(NSError **)error {
    setenv("HOME", home.fileSystemRepresentation, 1);
    int rc = -1;
    if (!ShackStartGuest(exePath, argv0, nil, dispatch_semaphore_create(0), &rc, error)) return nil;
    return @(rc);
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
