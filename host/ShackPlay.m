#import "ShackPlay.h"
#import "ShackJITHelper.h"
#import "ShackSteamClient.h"
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <sys/resource.h>

// MacShack's side of MacShack Play (README, "Windows games"): Play runs a Windows
// program (or the bridge checks, `--play-probe`) in front with Game Mode while MacShack, with Steam, keeps running in the background
// on silent audio and answers Play through their App Group's Mach service. Timestamped lines in
// Documents/Logs/play-<mode>.txt, rewritten after each line.

static NSString *g_bundleID, *g_logs;   // read at load: once a guest runs, mainBundle answers for the guest
__attribute__((constructor)) static void capturePlayPaths(void) {
    g_bundleID = NSBundle.mainBundle.bundleIdentifier;
    g_logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
}

static dispatch_queue_t g_queue;   // everything below runs on it
static NSMutableArray<NSString *> *g_report;
static CFAbsoluteTime g_start, g_awayAt;
static BOOL g_returned;            // Play's report merged for this program
static AVAudioEngine *g_silence;
static NSURL *g_group;
static NSString *g_mode = @"run";
static BOOL g_running;             // a program is out in MacShack Play
static void (^g_ended)(int status);
static _Atomic bool g_quit;        // Steam asked it to stop: ping replies say so
static _Atomic bool g_jitFailed;   // the JIT extension failed for this program's Play: ping replies say so
static unsigned g_starts;          // ShackPlayStart's count (g_queue): late callbacks and timers belong to their own start
static int g_pings;
static _Atomic long g_state = UIApplicationStateActive;   // from UIApplication's notifications
static BOOL g_alive;               // a Play process said hello and has not ended (its session right lives)
static BOOL g_met;                 // this program's Play process said hello

static void note(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void note(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    [g_report addObject:[NSString stringWithFormat:@"%7.1f s  %@", CFAbsoluteTimeGetCurrent() - g_start, line]];
    NSLog(@"[MacShack] play-%@: %@", g_mode, line);
    [NSFileManager.defaultManager createDirectoryAtPath:g_logs withIntermediateDirectories:YES attributes:nil error:NULL];
    [[g_report componentsJoinedByString:@"\n"] writeToFile:[g_logs stringByAppendingPathComponent:[NSString stringWithFormat:@"play-%@.txt", g_mode]]
                                                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static const char *stateName(void) {
    long state = atomic_load(&g_state);
    return state == UIApplicationStateActive ? "active" : state == UIApplicationStateInactive ? "inactive" : "background";
}

// Every 10 s while a program is out (the probe: every line; a game: each minute): still running (a gap means iOS
// suspended us), in which state, memory, CPU.
static void heartbeat(void) {
    static CFAbsoluteTime last;
    static double lastCPU;
    static unsigned tick;
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(), wall = last ? now - last : 0;
    BOOL gap = wall > 15;
    if (g_running && (gap || [g_mode isEqualToString:@"probe"] || tick++ % 6 == 0))
        note(@"heartbeat: %s, %@, cpu %.0f%%, thermal %ld%@", stateName(), ShackPlayUsage(),
             wall > 0 ? 100 * (cpu - lastCPU) / wall : 0, (long)NSProcessInfo.processInfo.thermalState,
             gap ? [NSString stringWithFormat:@", GAP of %.0f s (MacShack was not running)", wall] : @"");
    last = now;
    lastCPU = cpu;
}

// Silence on a mixable playback session while a program is out: with UIBackgroundModes audio, iOS keeps a playing app
// running in the background; mixable, so neither MacShack nor the game interrupts the other's audio.
static void startSilence(void) {
    if (g_silence) return;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    BOOL ok = [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                           options:AVAudioSessionCategoryOptionMixWithOthers error:&error] && [session setActive:YES error:&error];
    g_silence = [AVAudioEngine new];
    AVAudioFormat *format = [g_silence.outputNode inputFormatForBus:0];
    AVAudioSourceNode *zeros = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *out) {
            for (UInt32 i = 0; i < out->mNumberBuffers; i++) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
            return noErr;   // isSilence stays NO: the output must really run
        }];
    [g_silence attachNode:zeros];
    [g_silence connect:zeros to:g_silence.mainMixerNode format:format];
    ok = ok && [g_silence startAndReturnError:&error];
    note(@"keep-alive audio (playback, mix with others): %@", ok ? @"playing" : error.localizedDescription);
}

// The program's end, reported once: Play's own Exited, or Play's process gone without one (-1).
static void finish(int status) {
    if (!g_running) return;
    g_running = NO;
    note(@"MacShack Play's program ended (%d)", status);
    [g_silence stop];   // MacShack may be suspended in the background again: nothing is out
    g_silence = nil;
    if (g_ended) g_ended(status);
    g_ended = nil;
}

static void handle(const ShackPlayMessage *request, ShackPlayMessage *reply) {
    switch (request->kind) {
        case ShackPlayHello:
            g_alive = YES;
            g_met = YES;
            note(@"hello from MacShack Play (pid %d): session port sent, MacShack %s", request->pid, stateName());
            break;
        case ShackPlayPing:
            reply->value = atomic_load(&g_quit) ? ShackPlayQuit : atomic_load(&g_jitFailed) ? ShackPlayJITFailed : 0;
            static uint64_t said;   // a non-zero answer is logged when it changes: Play pings every 2 s (each line rewrites the report)
            if ([g_mode isEqualToString:@"probe"] || (reply->value && reply->value != said))
                note(@"ping %d from Play, MacShack %s%@", ++g_pings, stateName(), reply->value == ShackPlayQuit ? @": quit" : reply->value ? @": JIT failed" : @"");
            said = reply->value;
            break;
        case ShackPlayJIT: {
            pid_t pid = request->pid;
            unsigned start = g_starts;
            note(@"JIT asked for Play pid %d, MacShack %s: starting the JIT extension", pid, stateName());
            ShackJITHelperStartForPID(pid, g_queue, ^(BOOL ok, NSString *log) {
                note(@"JIT extension for pid %d: %@\n%@", pid, ok ? @"ok" : @"FAILED", log);
                if (!ok && start == g_starts) atomic_store(&g_jitFailed, true);   // a later program's Play is not told
            });
            break;
        }
        case ShackPlayExited:
            finish((int)request->value);
            break;
        case ShackPlaySteamIPC:   // Steam's ipcserver, for Play's Steam images
            reply->port.name = ShackSteamClientIPCPort();
            reply->port.disposition = MACH_MSG_TYPE_MOVE_SEND;
            note(@"Steam's ipcserver port for Play: %@", MACH_PORT_VALID(reply->port.name) ? @"sent" : @"none (Steam not running?)");
            break;
    }
}

// `--play-core`, MacShack's half of the link check: Application Support is a link into the shared home (ShackHome.m);
// a file written through it must be in the App Group (Play reads it through its own link, and writes one back).
static NSString *probeLink(void) {   // MacShack's probe folder, in the shared home through Application Support's link
    return [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"ShackProbe"];
}
static NSString *coreLinks(void) {   // g_queue
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *shared = [g_group.path stringByAppendingPathComponent:@"Home/Library/Application Support/ShackProbe"], *mine = probeLink();
    BOOL linked = [[fm attributesOfItemAtPath:mine.stringByDeletingLastPathComponent error:NULL].fileType isEqualToString:NSFileTypeSymbolicLink];
    NSError *e = nil;
    [fm createDirectoryAtPath:mine withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm removeItemAtPath:[mine stringByAppendingPathComponent:@"from-play.txt"] error:NULL];   // this run's Play writes it again
    NSString *token = NSUUID.UUID.UUIDString;
    BOOL wrote = [token writeToFile:[mine stringByAppendingPathComponent:@"from-macshack.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&e];
    BOOL read = [[NSString stringWithContentsOfFile:[shared stringByAppendingPathComponent:@"from-macshack.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqual:token];
    return [NSString stringWithFormat:@"links, MacShack: %@ (Application Support is a link %@, written through it %@, read in the App Group %@)%@",
            linked && wrote && read ? @"PASS" : @"FAIL", linked ? @"yes" : @"no", wrote ? @"yes" : @"no", read ? @"yes" : @"no",
            e ? [@": " stringByAppendingString:e.localizedDescription] : @""];
}

static void back(void) {   // MacShack in front again after Play: its report
    note(@"MacShack in front again after %.0f s away", CFAbsoluteTimeGetCurrent() - g_awayAt);
    NSString *play = g_group ? [NSString stringWithContentsOfURL:[g_group URLByAppendingPathComponent:[NSString stringWithFormat:@"play-%@-play.txt", g_mode]]
                                                        encoding:NSUTF8StringEncoding error:NULL] : nil;
    note(@"== MacShack Play's report\n%@\n== end of MacShack Play's report", play ?: @"(none in the App Group)");
    if ([g_mode isEqualToString:@"core"]) {
        NSString *fromPlay = [NSString stringWithContentsOfFile:[probeLink() stringByAppendingPathComponent:@"from-play.txt"] encoding:NSUTF8StringEncoding error:NULL];
        note(@"links, MacShack reads Play's file through its link: %@", fromPlay.length ? [@"PASS: " stringByAppendingString:fromPlay] : @"FAIL (not there)");
    }
}

static void observe(void) {   // main queue
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        atomic_store(&g_state, UIApplicationStateBackground);
        dispatch_async(g_queue, ^{
            if (!g_awayAt) g_awayAt = CFAbsoluteTimeGetCurrent();
            if (g_running) note(@"MacShack in the background");
        });
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        atomic_store(&g_state, UIApplicationStateInactive);
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        atomic_store(&g_state, UIApplicationStateActive);
        dispatch_async(g_queue, ^{
            if (g_awayAt && !g_returned) { g_returned = YES; back(); }
        });
    }];
    atomic_store(&g_state, UIApplication.sharedApplication.applicationState);
}

NSString *ShackPlayHostBundleID(void) { return g_bundleID; }

NSString *const ShackPlayMissing = @"MacShack Play is not installed. Every game runs in MacShack Play: install it, then start the game again.";
void ShackGameNotStarted(NSString *why) {
    NSLog(@"[MacShack] game not started: %@", why);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"ShackGameNotStarted" object:why];
    });
}

void ShackPlayRequestQuit(void) {
    atomic_store(&g_quit, true);
}

// iOS hands a link for Play to Play's process if one is still there, and that process runs one program only and
// ignores it: the last one leaves once it is in the background (MacShack in front again), which takes a moment.
// ponytail: waits up to 10 s in 100 ms steps; a Play process still there then gets no link (it would ignore it) and
// the program ends with EBUSY instead of waiting forever.
static void openPlay(NSURL *play, int stepsLeft, unsigned start) {   // g_queue
    if (g_alive && stepsLeft > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), g_queue, ^{ openPlay(play, stepsLeft - 1, start); });
        return;
    }
    if (g_alive) {
        note(@"the last MacShack Play process is still there after 10 s: not started");
        finish(EBUSY);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:play options:@{} completionHandler:^(BOOL ok) {
            dispatch_async(g_queue, ^{
                note(@"open %@: %@", play, ok ? @"ok" : @"FAILED (MacShack Play not installed?)");
                if (!ok) { ShackGameNotStarted(ShackPlayMissing); finish(ENOENT); return; }
                // A Play that never says hello (it did not start, or its signature expired): the program ends, so later
                // ones are not refused until MacShack restarts.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), g_queue, ^{
                    if (start != g_starts || g_met || !g_running) return;
                    note(@"MacShack Play did not say hello within 30 s: the program ends");
                    finish(ETIMEDOUT);
                });
            });
        }];
    });
}

void ShackPlayStart(NSString *mode, NSDictionary<NSString *, NSString *> *query, void (^ended)(int status)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{   // the bridge and the watchers, for the process's life
        g_queue = dispatch_queue_create("macshack.play", DISPATCH_QUEUE_SERIAL);
        g_report = [NSMutableArray array];
        dispatch_async(dispatch_get_main_queue(), ^{ observe(); });
        dispatch_async(g_queue, ^{
            g_group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(g_bundleID)];
            NSString *service = ShackPlayService(g_bundleID);
            kern_return_t kr = ShackPlayServe(service.UTF8String, g_queue, ^(const ShackPlayMessage *request, ShackPlayMessage *reply) {
                handle(request, reply);
            }, ^{
                g_alive = NO;
                if (!g_met) return;   // the last program's Play leaving after the next program started: not this one's end
                if (g_running) note(@"MacShack Play's process ended without reporting its program's end");
                finish(-1);
            });
            NSLog(@"[MacShack] MacShack Play bridge: Mach service %@: %s (0x%x)", service, ShackPlayError(kr), kr);
            static dispatch_source_t timer;
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_queue);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC, NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{ heartbeat(); });
            dispatch_resume(timer);
        });
    });
    dispatch_async(g_queue, ^{
        if (g_running) {
            ShackGameNotStarted(@"A game is still running in MacShack Play. Quit it there first.");
            if (ended) ended(EAGAIN);
            return;
        }
        g_mode = mode;
        g_running = YES;
        g_ended = ended;
        atomic_store(&g_quit, false);
        atomic_store(&g_jitFailed, false);
        unsigned start = ++g_starts;
        [g_report removeAllObjects];
        g_start = CFAbsoluteTimeGetCurrent();
        g_awayAt = 0;
        g_returned = NO;
        g_met = NO;
        note(@"MacShack play %@ %@: pid %d, %@", mode, query, getpid(), ShackPlayUsage());
        BOOL hello = NO;
        if (g_group) {
            [NSFileManager.defaultManager removeItemAtURL:[g_group URLByAppendingPathComponent:[NSString stringWithFormat:@"play-%@-play.txt", mode]] error:NULL];
            hello = [[NSString stringWithFormat:@"hello from MacShack pid %d", getpid()]
                     writeToURL:[g_group URLByAppendingPathComponent:@"play-probe-hello.txt"] atomically:YES
                       encoding:NSUTF8StringEncoding error:NULL];
        }
        note(@"App Group: %@", !g_group ? @"NO CONTAINER (entitlement missing?)" : hello ? g_group.path : @"container, but writing failed");
        if ([mode isEqualToString:@"core"]) note(@"%@", coreLinks());
        startSilence();
        NSURLComponents *url = [NSURLComponents new];
        url.scheme = [g_bundleID stringByAppendingString:@".play"];   // Play's bundle id, its URL scheme
        url.host = mode;
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
        [query enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [items addObject:[NSURLQueryItem queryItemWithName:k value:v]]; }];
        url.queryItems = items;
        openPlay(url.URL, 100, start);
    });
}

BOOL ShackWindowsGamesSetUp(void) {
    NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(ShackPlayHostBundleID())];
    return group && [NSFileManager.defaultManager fileExistsAtPath:[group.path stringByAppendingPathComponent:@"Windows/setup.json"]];
}

BOOL ShackWindowsGamesOn(void) {
    NSURL *play = [NSURL URLWithString:[ShackPlayHostBundleID() stringByAppendingString:@".play://"]];
    return ShackWindowsGamesSetUp() && play && [UIApplication.sharedApplication canOpenURL:play];
}
