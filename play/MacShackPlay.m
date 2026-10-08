#import "MadeiraEngine.h"
#import "MacShackPlay-Swift.h"
#import "PlaySteam.h"
#import "ShackJIT.h"
#import "ShackPlay.h"
#import "ShackTouchPad.h"
#import "ShackVAReport.h"
#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <sys/mman.h>
#import <time.h>

// MacShack Play: the frontmost app Windows programs run in, so they get Game Mode (8 GB, CPU/GPU priority) while
// MacShack keeps Steam running in the background (README, "Windows games").
// MacShack (host/ShackPlay.m) opens <its bundle id>.play://run?exe=... (a Windows program with Madeira's engine,
// play/MadeiraEngine.m), ://probe?minutes=N (the bridge checks, `--play-probe`) or ://steam?appid=N&seconds=S
// (Valve's steamclient logs on to MacShack's Steam, play/PlaySteam.m). Either way Play meets MacShack through their App
// Group's Mach service and has it start JIT for this pid, reports to Documents/Logs/play-<mode>.txt and the App
// Group's play-<mode>-play.txt, then goes back to MacShack and exits once iOS moves it to the background, so each
// program gets a fresh process.

static NSString *g_macshack;   // MacShack's bundle id: Play's is MacShack's + ".play" (project.yml)
static NSString *g_mode = @"probe";
static dispatch_queue_t g_queue;
static NSMutableArray<NSString *> *g_report;
static CFAbsoluteTime g_start;
static NSURL *g_group;
static mach_port_t g_session;   // MacShack's session port, once the hello worked
static _Atomic bool g_finished;   // over: leave when iOS moves Play to the background
static _Atomic bool g_background;   // Play is not in front (another app, e.g. MacShack for Steam's Stop)
static UILabel *g_status;   // main queue
static UIButton *g_home;    // main queue: the way to MacShack's Windows games screen, while no program or probe has started

static void note(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void note(NSString *format, ...) {   // from any queue
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[MacShack Play] %@", line);
    NSString *text;
    @synchronized (g_report) {
        [g_report addObject:[NSString stringWithFormat:@"%7.1f s  %@", CFAbsoluteTimeGetCurrent() - g_start, line]];
        text = [g_report componentsJoinedByString:@"\n"];
    }
    NSString *name = [NSString stringWithFormat:@"play-%@", g_mode];
    NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:NULL];
    [text writeToFile:[logs stringByAppendingPathComponent:[name stringByAppendingString:@".txt"]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (g_group) [text writeToURL:[g_group URLByAppendingPathComponent:[name stringByAppendingString:@"-play.txt"]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    dispatch_async(dispatch_get_main_queue(), ^{ g_status.text = [@"MacShack Play test\n" stringByAppendingString:line]; });
}

// What Game Mode gives the frontmost app: 6 GB at launch, 8 GB once it is on (about 2 s).
static void waitForGameMode(void) {   // g_queue
    for (int waited = 0; ; waited += 2) {
        note(@"limit after %d s: %@", waited, ShackPlayUsage());
        if (ShackPlayLimitMB() >= 7900 || waited >= 20) break;
        sleep(2);
    }
}

// The hello: MacShack's session port (a right that crossed between the apps); MacShack is in the background by now.
static BOOL meetMacShack(void) {   // g_queue
    g_group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(g_macshack)];
    NSString *service = ShackPlayService(g_macshack);
    kern_return_t kr = ShackPlayConnect(service.UTF8String, &g_session);
    note(@"Mach service %@: %s (0x%x)%@", service, ShackPlayError(kr), kr,
         kr == KERN_SUCCESS ? [NSString stringWithFormat:@", session port 0x%x received", g_session] : @"");
    return kr == KERN_SUCCESS;
}

// MacShack starts its JIT extension for this pid; the pool setup then waits for the debugger.
static void askJIT(void) {   // g_queue
    ShackPlayMessage reply;
    note(@"JIT request: %s", ShackPlayError(ShackPlayCall(g_session, ShackPlayJIT, 0, 5000, &reply)));
}

// Back to MacShack; this process ends when iOS moves it to the background (sceneDidEnterBackground:). A timer would
// not do: a backgrounded app is suspended within moments.
static void backToMacShack(void) {   // any queue, once
    if (atomic_exchange(&g_finished, true)) return;
    NSURL *macshack = [NSURL URLWithString:[g_macshack stringByAppendingString:@"://play-done"]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:macshack options:@{} completionHandler:^(BOOL ok) {
            note(@"open MacShack: %@", ok ? @"ok" : @"FAILED");
        }];
    });
}

static NSString *ping(BOOL *answered) {
    if (!MACH_PORT_VALID(g_session)) { *answered = NO; return @"no session"; }
    ShackPlayMessage reply;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    kern_return_t kr = ShackPlayCall(g_session, ShackPlayPing, 0, 5000, &reply);
    double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    *answered = kr == KERN_SUCCESS;
    return *answered ? [NSString stringWithFormat:@"MacShack answered in %.2f ms", ms]
                     : [NSString stringWithFormat:@"MacShack DID NOT ANSWER: %s (0x%x) after %.0f ms", ShackPlayError(kr), kr, ms];
}

static void fill(uint64_t *words, size_t bytes, uint64_t seed) {   // xorshift: incompressible, the compressor cannot hide it
    uint64_t x = seed * 0x9E3779B97F4A7C15ull | 1;
    for (size_t i = 0; i < bytes / 8; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; words[i] = x; }
}

// The bridge checks: Game Mode, App Group, Mach, JIT, then memory toward the limit while MacShack must keep answering.
static void runProbe(NSUInteger minutes) {   // g_queue
    note(@"MacShack Play probe: pid %d, MacShack is %@, hold %lu min", getpid(), g_macshack, (unsigned long)minutes);
    waitForGameMode();
    BOOL met = meetMacShack();
    NSString *hello = g_group ? [NSString stringWithContentsOfURL:[g_group URLByAppendingPathComponent:@"play-probe-hello.txt"]
                                                         encoding:NSUTF8StringEncoding error:NULL] : nil;
    note(@"App Group %@: %@", ShackPlayGroup(g_macshack), !g_group ? @"NO CONTAINER (entitlement missing?)" : hello ?: @"container, but no hello from MacShack");
    BOOL answered = NO;
    for (int i = 1; i <= 5 && met; i++) note(@"ping %d: %@", i, ping(&answered));
    if (met) {
        askJIT();
        note(@"%@", [ShackJITCheck(128) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    }
    const size_t step = 256ull << 20;
    NSMutableArray<NSValue *> *chunks = [NSMutableArray array];
    while (os_proc_available_memory() > step + (512ull << 20)) {
        void *p = mmap(NULL, step, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { note(@"climb: mmap failed: %s", strerror(errno)); break; }
        fill(p, step, chunks.count + 1);
        [chunks addObject:[NSValue valueWithPointer:p]];
        note(@"climb %lu MB: %@; %@", (unsigned long)chunks.count * 256, ShackPlayUsage(), ping(&answered));
        if (!answered && met) break;
    }
    note(@"climb stopped with %lu MB held", (unsigned long)chunks.count * 256);
    for (NSUInteger s = 10; s <= minutes * 60; s += 10) {   // hold like a game, pinging every 10 s
        sleep(10);
        note(@"hold %lu s: %@; %@", (unsigned long)s, ShackPlayUsage(), ping(&answered));
    }
    for (NSValue *chunk in chunks) munmap(chunk.pointerValue, step);
    note(@"freed: %@. Back to MacShack.", ShackPlayUsage());
    backToMacShack();
}

// GameController -> XInput's layout, as Madeira's GamepadInput does it.
static ShackPadState padState(GCExtendedGamepad *p) {
    ShackPadState s = {0};
    s.connected = 1;
    struct { GCControllerButtonInput *b; uint16_t bit; } map[] = {
        {p.dpad.up, 0x0001}, {p.dpad.down, 0x0002}, {p.dpad.left, 0x0004}, {p.dpad.right, 0x0008},
        {p.buttonMenu, 0x0010}, {p.buttonOptions, 0x0020}, {p.leftThumbstickButton, 0x0040},
        {p.rightThumbstickButton, 0x0080}, {p.leftShoulder, 0x0100}, {p.rightShoulder, 0x0200}, {p.buttonHome, 0x0400},
        {p.buttonA, 0x1000}, {p.buttonB, 0x2000}, {p.buttonX, 0x4000}, {p.buttonY, 0x8000},
    };
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) if (map[i].b.isPressed) s.buttons |= map[i].bit;
    int16_t (^axis)(float) = ^int16_t(float v) { return (int16_t)(MIN(MAX(v, -1.f), 1.f) * 32767); };
    s.lx = axis(p.leftThumbstick.xAxis.value); s.ly = axis(p.leftThumbstick.yAxis.value);
    s.rx = axis(p.rightThumbstick.xAxis.value); s.ry = axis(p.rightThumbstick.yAxis.value);
    s.left_trigger = (uint8_t)(MIN(MAX(p.leftTrigger.value, 0.f), 1.f) * 255);
    s.right_trigger = (uint8_t)(MIN(MAX(p.rightTrigger.value, 0.f), 1.f) * 255);
    return s;
}

// Every pad, 120 times a second, to the engine when it changed (main queue: GameController objects live there).
static void startPads(void) {
    static NSTimer *timer;
    static ShackPadState sent[4];
    static BOOL had[4];
    timer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(__unused NSTimer *t) {
        NSArray<GCController *> *pads = [GCController.controllers filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(GCController *c, id _) { return c.extendedGamepad != nil; }]];
        for (NSUInteger i = 0; i < 4; i++) {
            BOOL has = i < pads.count;
            ShackPadState s = has ? padState(pads[i].extendedGamepad) : (ShackPadState){0};
            if (has == had[i] && (!has || !memcmp(&s, &sent[i], sizeof s))) continue;
            if (MadeiraEnginePad((NSInteger)i, has ? &s : NULL)) { had[i] = has; sent[i] = s; }   // kept until the engine takes it
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

// MacShack's on-screen controller over the program while no physical pad is connected (host/TouchControls.swift): its pad
// is a GCController (host/ShackTouchPad.m), so startPads hands it to the program like any pad. Touches outside the
// controls stay the program's (mouse). Main queue.
static void showTouchControls(UIView *over) {
    TouchControlsView *controls = [[TouchControlsView alloc] initWithFrame:over.bounds];
    controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [over addSubview:controls];
    void (^update)(NSNotification *) = ^(NSNotification *n) {
        BOOL physical = [GCController.controllers indexOfObjectPassingTest:^BOOL(GCController *c, NSUInteger i, BOOL *stop) {
            return c.extendedGamepad && ![NSStringFromClass(c.class) isEqualToString:@"ShackTouchPadController"];
        }] != NSNotFound;
        controls.hidden = physical;
        ShackTouchPadSetConnected(!physical);   // posts its own connect: update runs again and changes nothing
    };
    for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:update];
    update(nil);
}

@interface ShackPlayView : UIView
@property (strong) CADisplayLink *link;
@property (strong) id<MTLCommandQueue> commands;
- (void)startClearing;
@end

static ShackPlayView *g_view;   // main queue: full screen; a Windows program draws into its CAMetalLayer

// The program's end for Steam (MacShack's stand-in process), once: before going back.
static void reportExit(int status) {
    static _Atomic bool sent;
    if (!MACH_PORT_VALID(g_session) || atomic_exchange(&sent, true)) return;
    ShackPlayMessage reply;
    note(@"exit %d reported to MacShack: %s", status, ShackPlayError(ShackPlayCall(g_session, ShackPlayExited, (uint64_t)status, 5000, &reply)));
}

// Steam's Stop reaches Play through ping replies: the program ends with this process.
static void watchForQuit(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{
        ShackPlayMessage reply;
        if (ShackPlayCall(g_session, ShackPlayPing, 0, 2000, &reply) != KERN_SUCCESS || reply.value != ShackPlayQuit) return;
        dispatch_source_cancel(timer);
        note(@"Steam asked the program to stop");
        reportExit(0);
        if (atomic_load(&g_background)) exit(0);   // MacShack is in front already (its Stop): just end
        backToMacShack();
    });
    dispatch_resume(timer);
}

// The prefix's Steam folder as NotProton stages it (its compat_run.sh bridge_files): Valve's Windows client files
// (Windows/engine/steam: steamclient64.dll, tier0_s64.dll, ...), which a game's steam_api loads and Play's ntdll detour
// points at lsteamclient. Copied when missing or changed.
static NSString *stagePrefixSteam(NSString *prefix) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *from = [MadeiraEngineDirectory() stringByAppendingPathComponent:@"steam"];   // Valve's files, steam.exe, ... (WindowsKit.swift)
    if (![fm fileExistsAtPath:from]) return @"prefix Steam folder: no Windows/engine/steam (Windows games not set up)";
    NSString *to = [prefix stringByAppendingPathComponent:@"drive_c/Program Files (x86)/Steam"];
    [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableArray *staged = [NSMutableArray array];
    for (NSString *f in [fm contentsOfDirectoryAtPath:from error:nil]) {
        NSString *src = [from stringByAppendingPathComponent:f], *dst = [to stringByAppendingPathComponent:f];
        if ([fm contentsEqualAtPath:src andPath:dst]) continue;
        [fm removeItemAtPath:dst error:NULL];
        if ([fm copyItemAtPath:src toPath:dst error:NULL]) [staged addObject:f];
    }
    return [NSString stringWithFormat:@"prefix Steam folder: %@", staged.count ? [staged componentsJoinedByString:@", "] : @"up to date"];
}

// MacShack's Steam for lsteamclient in this process (the Steam API in Windows games): Valve's steamclient set ready,
// its folder for the unix half.
static NSString *steamForWine(void) {   // g_queue, after the hello
    ShackPlayMessage reply;
    kern_return_t kr = ShackPlayCall(g_session, ShackPlaySteamIPC, 0, 5000, &reply);
    NSString *error = nil, *macos = PlaySteamPrepare(g_group, kr == KERN_SUCCESS ? reply.port.name : MACH_PORT_NULL, &error);
    if (!macos) return [@"Steam for lsteamclient: FAILED: " stringByAppendingString:error];
    setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", macos.fileSystemRepresentation, 1);
    return [@"Steam for lsteamclient: steamclient.dylib in " stringByAppendingString:macos];
}

// What `to` lacks of `from`, recursively (NotProton's merge_user_dir). Links are skipped: Wine's links to unix folders.
static void mergeMissing(NSString *from, NSString *to) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [fm contentsOfDirectoryAtPath:from error:NULL]) {
        NSString *src = [from stringByAppendingPathComponent:name], *dst = [to stringByAppendingPathComponent:name];
        NSString *type = [fm attributesOfItemAtPath:src error:NULL].fileType;
        BOOL dir = NO;
        if ([type isEqualToString:NSFileTypeSymbolicLink]) continue;
        if (![fm fileExistsAtPath:dst isDirectory:&dir]) [fm copyItemAtPath:src toPath:dst error:NULL];
        else if (dir && [type isEqualToString:NSFileTypeDirectory]) mergeMissing(src, dst);
    }
}

// Steam Cloud keeps a Steam Play game's files under the prefix's users/steamuser (Proton's Wine user; Steam fills it
// before the launch), and Wine takes its user name from USER (HOME is iOS's). As NotProton's lay_out_proton_profile
// (whose Wine user is crossover): steamuser is the profile; an older one (Madeira's madeira) gives it what it lacks,
// stays beside it as <name>.previous, and its name becomes a link to steamuser.
static NSString *useSteamProfile(NSString *prefix) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *users = [prefix stringByAppendingPathComponent:@"drive_c/users"], *profile = [users stringByAppendingPathComponent:@"steamuser"];
    for (NSString *dir in @[@"Desktop", @"Documents", @"Downloads", @"Music", @"Pictures", @"Videos", @"Templates",
                            @"AppData/Local", @"AppData/LocalLow", @"AppData/Roaming"])
        [fm createDirectoryAtPath:[profile stringByAppendingPathComponent:dir] withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("USER", "steamuser", 1);
    NSMutableArray<NSString *> *merged = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:users error:NULL]) {
        NSString *old = [users stringByAppendingPathComponent:name];
        if ([@[@"steamuser", @"Public"] containsObject:name] || [name hasSuffix:@".previous"] ||
            ![[fm attributesOfItemAtPath:old error:NULL].fileType isEqualToString:NSFileTypeDirectory]) continue;
        mergeMissing(old, profile);
        if ([fm moveItemAtPath:old toPath:[old stringByAppendingString:@".previous"] error:NULL])
            [fm createSymbolicLinkAtPath:old withDestinationPath:@"steamuser" error:NULL];
        [merged addObject:name];
    }
    return [NSString stringWithFormat:@"Wine user steamuser (Steam Cloud's profile)%@", merged.count
            ? [NSString stringWithFormat:@"; merged %@ into it, kept as .previous", [merged componentsJoinedByString:@", "]] : @""];
}

// One plain file name: a value from the URL joined to a folder never leads outside it or to the folder itself
// ("a/b", "/x", "/", "..", "." are not names).
static BOOL plainName(NSString *name) {
    return name.length > 0 && ![name containsString:@"/"] && ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

// A Windows program with Madeira's engine, in front with Game Mode.
static void runGame(NSDictionary<NSString *, NSString *> *query) {   // g_queue
    note(@"MacShack Play: %@ (pid %d), MacShack is %@", query[@"exe"], getpid(), g_macshack);
    // The test program (not an absolute path) and the result file are names in a folder of Play's own.
    NSString *exe = query[@"exe"] ?: @"cube-x64.exe", *resultName = query[@"result"];
    if ((resultName.length && !plainName(resultName)) || (![exe hasPrefix:@"/"] && !plainName(exe))) {
        note(@"refused: exe (unless an absolute path) and result must each be one plain file name");
        if (meetMacShack()) reportExit(EINVAL);   // as a program's end: MacShack and Steam's stand-in process stop waiting for it
        backToMacShack();
        return;
    }
    waitForGameMode();
    AVAudioSession *session = AVAudioSession.sharedInstance;   // mixable: MacShack's own (silent) audio keeps it running
    NSError *error = nil;
    BOOL audio = [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                              options:AVAudioSessionCategoryOptionMixWithOthers error:&error] && [session setActive:YES error:&error];
    note(@"audio session (playback, mix with others): %@", audio ? @"active" : error.localizedDescription);
    if (meetMacShack()) { askJIT(); watchForQuit(); }
    if (query[@"steam"].length) note(@"%@", steamForWine());
    if (query[@"winedebug"].length) setenv("WINEDEBUG", query[@"winedebug"].UTF8String, 1);   // Wine's debug channels, for a diagnosis
    note(@"%@", ShackVAReport(NO));
    NSString *install = query[@"install"], *compat = query[@"compat"];
    NSString *test = [MadeiraEngineDirectory() stringByAppendingPathComponent:exe];   // nil without the App Group
    BOOL testIsDirectory = NO,
         testIsFile = [NSFileManager.defaultManager fileExistsAtPath:test isDirectory:&testIsDirectory] && !testIsDirectory;
    NSMutableDictionary *request = [@{@"run": exe, @"hud": @(query[@"hud"] != nil)} mutableCopy];
    for (NSString *key in @[@"args", @"screen"]) if (query[key].length) request[key] = query[key];
    for (NSString *key in @[@"jitMB", @"seconds", @"fpsMode"]) if (query[key].length) request[key] = @(query[key].doubleValue);
    if (compat.length && install.length && [exe hasPrefix:[install stringByAppendingString:@"/"]]) {
        // A Steam game (Steam Play): its own prefix in its compatdata, its folder linked in, its Steam identity.
        request[@"game"] = install.lastPathComponent;
        request[@"gameDir"] = install;
        request[@"run"] = [[exe substringFromIndex:install.length + 1] stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
        request[@"prefix"] = [compat stringByAppendingPathComponent:@"pfx"];
        note(@"%@", useSteamProfile(request[@"prefix"]));
        if (query[@"appid"].length) {
            request[@"steamAppID"] = query[@"appid"];
            setenv("SteamAppId", query[@"appid"].UTF8String, 1);
            setenv("SteamGameId", query[@"appid"].UTF8String, 1);
        }
    } else if ([exe hasPrefix:@"/"]) {
        request[@"run"] = [@"Z:" stringByAppendingString:[exe stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];   // Wine's Z: is /
    } else if (testIsFile) {
        // a test program (a file) from the kit (Windows/engine): Wine cannot open the App Group's folder via Z:
        NSString *driveC = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                             stringByAppendingPathComponent:@"wine"] stringByAppendingPathComponent:@"drive_c"];
        [NSFileManager.defaultManager createDirectoryAtPath:driveC withIntermediateDirectories:YES attributes:nil error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[driveC stringByAppendingPathComponent:exe] error:NULL];
        [NSFileManager.defaultManager copyItemAtPath:test toPath:[driveC stringByAppendingPathComponent:exe] error:NULL];
        request[@"run"] = [@"C:\\" stringByAppendingString:exe];
    }
    if (query[@"shim"].length) {
        // NotProton's launch (compat_run.sh): steam.exe with the program as its arguments; it sets ActiveProcess and
        // Steam's registry, logs on through steamclient64 (lsteamclient), starts the program and waits for it.
        // Madeira splits its own arguments at spaces and keeps quotes, so the command line goes to Play's launcher
        // (windows-kit/helpers/launch.c) whole, in MONO_MACSHACK_LAUNCH, with the game's folder as the working folder.
        NSString *args = request[@"args"], *dir = request[@"game"]
            ? [@"C:\\Program Files (x86)\\Steam\\steamapps\\common\\" stringByAppendingString:request[@"game"]] : @"C:\\";
        NSString *program = request[@"game"] ? [NSString stringWithFormat:@"%@\\%@", dir, request[@"run"]] : request[@"run"];
        setenv("MONO_MACSHACK_LAUNCH", [NSString stringWithFormat:@"\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%@\"%@", program,
                                        args.length ? [@" " stringByAppendingString:args] : @""].UTF8String, 1);
        setenv("MONO_MACSHACK_LAUNCH_DIR", dir.UTF8String, 1);
        [request removeObjectForKey:@"args"];
        request[@"run"] = @"C:\\Program Files (x86)\\Steam\\macshack-launch.exe";
        if (!request[@"steamAppID"] && query[@"appid"].length) request[@"steamAppID"] = query[@"appid"];
        request[@"wineDefaultShutdown"] = @YES;   // steam.exe exits once the game has (MadeiraEngine.m)
    }
    if (query[@"steam"].length) setenv("WINEDLLOVERRIDES", "steamclient=n;steamclient64=n;lsteamclient=b", 1);   // NotProton's
    __block CAMetalLayer *layer;
    dispatch_sync(dispatch_get_main_queue(), ^{ layer = (CAMetalLayer *)g_view.layer; startPads(); });
    if (query[@"steam"].length)
        note(@"%@", stagePrefixSteam(request[@"prefix"] ?: [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                                                            stringByAppendingPathComponent:@"wine"]));
    NSString *result = query[@"result"].length ? [[request[@"prefix"] ?: [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                        stringByAppendingPathComponent:@"wine"] stringByAppendingPathComponent:@"drive_c"] stringByAppendingPathComponent:query[@"result"]] : nil;
    if (result) [NSFileManager.defaultManager removeItemAtPath:result error:NULL];
    note(@"%@", MadeiraEngineRun(request, layer));
    if (result) note(@"C:\\%@:\n%@", query[@"result"], [NSString stringWithContentsOfFile:result encoding:NSUTF8StringEncoding error:NULL] ?: @"(not written)");
    reportExit(0);
    backToMacShack();
}

// The first step toward the Steam API in Windows games (lsteamclient): Valve's steamclient here logs on to MacShack's
// Steam (play/PlaySteam.m), no Wine. Steam's own output (stderr) goes to Documents/Logs/play-steam-stderr.txt.
static void runSteam(NSDictionary<NSString *, NSString *> *query) {   // g_queue
    NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:NULL];
    freopen([logs stringByAppendingPathComponent:@"play-steam-stderr.txt"].fileSystemRepresentation, "w", stderr);
    setvbuf(stderr, NULL, _IOLBF, 0);
    note(@"MacShack Play: Steam client test (pid %d, Steam sees %d), MacShack is %@", getpid(), ShackPlaySteamPid, g_macshack);
    mach_port_t ipc = MACH_PORT_NULL;
    if (meetMacShack()) {
        ShackPlayMessage reply;
        kern_return_t kr = ShackPlayCall(g_session, ShackPlaySteamIPC, 0, 5000, &reply);
        if (kr == KERN_SUCCESS) ipc = reply.port.name;
        note(@"Steam's ipcserver port from MacShack: %s, port 0x%x", ShackPlayError(kr), ipc);
    }
    unsigned seconds = query[@"seconds"].length ? (unsigned)query[@"seconds"].integerValue : 30;
    uint32_t app = query[@"appid"].length ? (uint32_t)query[@"appid"].longLongValue : 480;
    note(@"%@", PlaySteamProbe(g_group, ipc, app, seconds, ^(NSString *line) { note(@"%@", line); }));
    reportExit(0);
    backToMacShack();
}

// The home screen, while no program or probe has started (Play opened by hand, or by MacShack's "Open MacShack Play"):
// whether Windows games are set up, and a button to MacShack's Windows games screen. Setup lives there: MacShack holds
// the signing certificate and Steam. Idempotent: the button is made once, the texts are read again each call (on coming
// back from MacShack after the setup).
static void showHome(UIView *view) {
    if (g_home.hidden) return;   // a run has the screen (start)
    BOOL ready = [NSFileManager.defaultManager fileExistsAtPath:[MadeiraEngineDirectory().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"setup.json"]];
    g_status.text = ready ? @"MacShack Play\nWindows games are set up. Start them from Steam Big Picture in MacShack."
                          : @"MacShack Play\nWindows games are not set up yet.";
    if (!g_home) {
        g_home = [UIButton buttonWithType:UIButtonTypeSystem];
        g_home.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        g_home.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
        [g_home addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSURL *url = [NSURL URLWithString:[g_macshack stringByAppendingString:@"://windows-games"]];
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }] forControlEvents:UIControlEventTouchUpInside];
        [view addSubview:g_home];
    }
    [g_home setTitle:ready ? @"Windows games in MacShack" : @"Set up Windows games" forState:UIControlStateNormal];
    [g_home sizeToFit];
    g_home.center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMaxY(view.bounds) - 80);
}

static void start(UIOpenURLContext *context) {   // main queue: one probe or program per process
    static BOOL started;
    NSURL *url = context.URL;
    NSString *mode = url.host;
    if (started || !([mode isEqualToString:@"probe"] || [mode isEqualToString:@"run"] || [mode isEqualToString:@"steam"])) return;
    // iOS sets sourceApplication only for apps of the same team: MacShack opens Play for runs, so another app (or none
    // iOS names) gets nothing, and a program or probe never starts from a link elsewhere. The line shows what the first
    // run on a device gets. A bare <id>.play:// (no mode) only shows the home, from anyone.
    NSString *source = context.options.sourceApplication;
    BOOL fromMacShack = [source isEqualToString:g_macshack];
    g_mode = fromMacShack ? mode : @"refused";   // note() names its file after the mode: an ignored link keeps off a run's
    note(@"opened by %@%@", source ?: @"(none)", fromMacShack ? @"" : @", not MacShack: ignored");
    if (!fromMacShack) return;   // the home screen stays up
    started = YES;
    g_home.hidden = YES;
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
        if (item.value) query[item.name] = item.value;
    if ([mode isEqualToString:@"run"]) {
        g_status.hidden = YES;   // the program has the screen
        showTouchControls(g_view);
        dispatch_async(g_queue, ^{ runGame(query); });
    } else if ([mode isEqualToString:@"steam"]) {
        dispatch_async(g_queue, ^{ runSteam(query); });
    } else {
        [g_view startClearing];
        NSUInteger minutes = query[@"minutes"].integerValue > 0 ? (NSUInteger)query[@"minutes"].integerValue : 10;
        dispatch_async(g_queue, ^{ runProbe(minutes); });
    }
}

@implementation ShackPlayView
+ (Class)layerClass { return CAMetalLayer.class; }

// The probe's light GPU load, as a game would be: one clear per frame.
- (void)startClearing {
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.device = MTLCreateSystemDefaultDevice();
    self.commands = [layer.device newCommandQueue];
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)frame:(CADisplayLink *)link {
    id<CAMetalDrawable> drawable = [(CAMetalLayer *)self.layer nextDrawable];
    if (!drawable) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.1 + 0.05 * sin(CACurrentMediaTime()), 0.2, 1);
    id<MTLCommandBuffer> buffer = [self.commands commandBuffer];
    [[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
}

// Touches in the program's image (aspect fit), 0...1, as Madeira's mapTouch.
- (void)send:(NSInteger)phase touch:(UITouch *)touch {
    CGSize b = self.bounds.size, f = ((CAMetalLayer *)self.layer).drawableSize;
    if (!touch || !f.width || !f.height) return;
    CGFloat scale = MIN(b.width / f.width, b.height / f.height);
    CGRect r = CGRectMake((b.width - f.width * scale) / 2, (b.height - f.height * scale) / 2, f.width * scale, f.height * scale);
    CGPoint p = [touch locationInView:self];
    MadeiraEngineTouch(phase, MIN(MAX((p.x - r.origin.x) / r.size.width, 0), 1), MIN(MAX((p.y - r.origin.y) / r.size.height, 0), 1));
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:0 touch:t.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:1 touch:t.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:2 touch:t.anyObject]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self send:2 touch:t.anyObject]; }
@end

@interface ShackPlaySceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation ShackPlaySceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    g_view = [[ShackPlayView alloc] initWithFrame:self.window.bounds];
    g_view.backgroundColor = UIColor.blackColor;
    controller.view = g_view;
    g_status = [[UILabel alloc] initWithFrame:CGRectInset(g_view.bounds, 40, 40)];
    g_status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_status.numberOfLines = 0;
    g_status.textColor = UIColor.whiteColor;
    g_status.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    g_status.text = @"MacShack Play\nopened by MacShack to run Windows programs";
    [g_view addSubview:g_status];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    showHome(g_view);   // start() below hides it when a program or probe starts
    for (UIOpenURLContext *context in options.URLContexts) start(context);
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    for (UIOpenURLContext *context in contexts) start(context);
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    atomic_store(&g_background, true);
    if (g_finished) exit(0);
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
    atomic_store(&g_background, false);
    if (g_view) showHome(g_view);
}
@end

@interface ShackPlayAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShackPlayAppDelegate
@end

int main(int argc, char *argv[]) {
    MadeiraEngineHoldPoolSpace();   // before UIKit, Metal and Steam map anything
    @autoreleasepool {
        g_macshack = [NSBundle.mainBundle.bundleIdentifier stringByDeletingPathExtension];
        g_queue = dispatch_queue_create("macshack.play", DISPATCH_QUEUE_SERIAL);
        g_report = [NSMutableArray array];
        g_start = CFAbsoluteTimeGetCurrent();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ShackPlayAppDelegate.class));
    }
}
