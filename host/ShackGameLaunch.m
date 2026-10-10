#import "ShackGameLaunch.h"
#import "ShackHooks.h"
#import "ShackMetal.h"
#import "ShackSwap.h"
#import <dlfcn.h>
#import <locale.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <unistd.h>
#import <crt_externs.h>

// How MacShack starts a Mac game in its own process, shared with MacShack Play (which runs Mac games too).

typedef int (*guest_main_t)(int, char **, char **, char **);
extern char **environ;
extern void ShackSetGuestCommandLine(int argc, char **argv);

static NSError *err(NSString *msg) { return [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

static const struct mach_header_64 *headerForPath(NSString *path) {
    // realpath, not stringByResolvingSymlinksInPath: the latter strips /private, dyld keeps it.
    char want[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, want)) return NULL;
    for (uint32_t i = _dyld_image_count(); i-- > 0;) {
        const char *n = _dyld_get_image_name(i);
        if (n && strcmp(n, want) == 0) return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

static guest_main_t entryPoint(const struct mach_header_64 *h) {
    const uint8_t *p = (const uint8_t *)h + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_MAIN) return (guest_main_t)((const uint8_t *)h + ((const struct entry_point_command *)lc)->entryoff);
        p += lc->cmdsize;
    }
    return NULL;
}

struct guest_args { const char *path; guest_main_t main; int argc; char **argv; int rc; dispatch_semaphore_t loaded, done; NSString *loadError; };

// The guest image is loaded on the thread that then runs its main, as in a Mac process: static initializers record
// "the main thread" (Godot 3's Thread::main_thread_id), and a game whose main ran elsewhere deferred its GDNative
// plugins forever (Cosmic Call: GodotSteam never loaded, Steam stayed null).
static void *guestThread(void *arg) {
    struct guest_args *g = arg;
    pthread_setname_np("guest-main");
    *_NSGetArgc() = g->argc;
    *_NSGetArgv() = g->argv;
    ShackSetGuestCommandLine(g->argc, g->argv);
    void *h = dlopen(g->path, RTLD_NOW | RTLD_GLOBAL | RTLD_FIRST);
    const struct mach_header_64 *hdr = h ? headerForPath(@(g->path)) : NULL;
    g->main = hdr ? entryPoint(hdr) : NULL;
    if (!h) g->loadError = @(dlerror());
    else if (!g->main) g->loadError = @"guest image loaded but LC_MAIN not found";
    dispatch_semaphore_signal(g->loaded);
    if (g->loadError) return NULL;
    g->rc = g->main(g->argc, g->argv, environ, NULL);   // ponytail: `apple` vector NULL; add if a game reads it
    if (!g->done) { NSLog(@"[MacShack] guest main returned %d", g->rc); ShackGuestEnded(g->rc); }   // SDL games end here
    if (g->done) dispatch_semaphore_signal(g->done);
    return NULL;
}

// Intel engine defaults, so a game needs no .args (MacShack's list and the Steam client alike): Unity renders with Metal
// when its build has Metal shaders (-force-metal for Unity 2018 and older); desktop GL on ES (CGL included) serves the
// rest: Chowdren, SDL, and Unity builds that ship only GL shaders (Subnautica, Aragami). Sets SHACK_OPENGL, which
// ShackHooksInstall reads (a later guest calls ShackHooksEnableGL).
NSArray<NSString *> *ShackTranslatedArgs(NSString *appPath, NSArray<NSString *> *args) {
    BOOL unity = [NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingPathComponent:@"Contents/Resources/Data"]];
    BOOL renderer = NO;
    for (NSString *a in args) renderer |= [a hasPrefix:@"-force-"] && ([a hasSuffix:@"metal"] || [a hasSuffix:@"glcore"] || [a hasSuffix:@"opengl"]);
    setenv("SHACK_OPENGL", "1", 0);
    return unity && !renderer ? [args arrayByAddingObject:@"-force-metal"] : args;
}

// Translated x86 fills a pool faster than Mono (Hades: 51 MB in its first 14 s; Celeste's x86 Mono JIT: 256 MB in
// 4.5 min); a full pool runs new code interpreted, which Celeste did not survive. ponytail: AArchX never reuses its
// pool; flushing it when full (or sharing block prologues, ~100 words each) is the real fix.
// Rewired (Unity) maps the virtual pad's 2019 Xbox identity as an unknown controller before 2019 (Cuphead: up/down
// swapped) and knows the 2016 one in every version (ShackHID.m).
BOOL ShackWantsXbox2016(NSString *appPath) {
    return [NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingString:@"/Contents/Resources/Data/Managed/Rewired_Core.dll"]];
}

int ShackTranslatedJITMB(NSString *appPath) {
    return [NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingPathComponent:@"Contents/Resources/monoconfig"]] ? 1024 : 512;
}

void ShackRedirectOutput(NSString *logPath) {
    // The previous run's log survives one relaunch (a crash is usually reported after the game was started again).
    rename(logPath.fileSystemRepresentation, [logPath.stringByDeletingPathExtension stringByAppendingString:@".prev.log"].fileSystemRepresentation);
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IONBF, 0);
}

BOOL ShackStartGuest(NSString *exePath, NSString *argv0, NSArray<NSString *> *args, dispatch_semaphore_t done, int *rcOut, NSError **error) {
    static struct guest_args g;
    int argc = 1 + (int)args.count;
    char **argv = calloc((size_t)argc + 1, sizeof *argv);   // lives for the process
    argv[0] = strdup(argv0.fileSystemRepresentation);
    for (int i = 1; i < argc; i++) argv[i] = strdup(args[(NSUInteger)i - 1].UTF8String);
    g = (struct guest_args){ strdup(exePath.fileSystemRepresentation), NULL, argc, argv, 0, dispatch_semaphore_create(0), done, nil };
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64 << 20);
    pthread_t t; int e = pthread_create(&t, &at, guestThread, &g);
    if (e) { if (error) *error = err([NSString stringWithFormat:@"pthread_create: %d", e]); return NO; }
    // Static initializers may hop to the main queue (ShackMainSync): keep this thread's run loop turning while waiting.
    while (dispatch_semaphore_wait(g.loaded, DISPATCH_TIME_NOW)) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    if (g.loadError) { if (error) *error = err(g.loadError); return NO; }
    if (done) { dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); if (rcOut) *rcOut = g.rc; }
    return YES;
}

// Documents/Games/<Name>.args: one argument per line; written with defaults on first launch so the user can edit it.
// --shack-watch (opts into ShackWatchStart's full sampling/capture) and --shack-jit-mb=N (Mono JIT pool size,
// default 128) and --shack-gputrace[=S] (allows GPU traces: on request via Documents/Logs/gputrace.request, and after S seconds if given) are MacShack-only tokens,
// stripped before the args reach the guest. --shack-env=NAME=VALUE sets an environment variable for the game
// (SHACK_OPENGL=1: desktop OpenGL on ES for GLFW guests, shims/AppKit/ShackGL.m).
NSArray<NSString *> *ShackGuestArgs(NSString *path, BOOL *watchOut, int *jitMBOut, int *traceSecOut) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) {
        // Unity's flags only for Unity games (Contents/Resources/Data): strict parsers reject them (Factorio: "-s").
        NSString *data = [[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"app"] stringByAppendingPathComponent:@"Contents/Resources/Data"];
        text = [NSFileManager.defaultManager fileExistsAtPath:data] ? @"-stdout\n-FullStdOutLogOutput\n-nosplash\n" : @"";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSMutableArray *a = [NSMutableArray array];
    BOOL watch = NO;
    for (NSString *l in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!t.length) continue;
        if ([t isEqualToString:@"--shack-watch"]) { watch = YES; continue; }
        if ([t hasPrefix:@"--shack-gputrace"]) { int sec = [t hasPrefix:@"--shack-gputrace="] ? [t substringFromIndex:17].intValue : 0; *traceSecOut = sec > 0 ? sec : -1; continue; }
        if ([t hasPrefix:@"--shack-env="]) {
            NSString *kv = [t substringFromIndex:12]; NSRange eq = [kv rangeOfString:@"="];
            if (eq.location != NSNotFound && eq.location) setenv([kv substringToIndex:eq.location].UTF8String, [kv substringFromIndex:NSMaxRange(eq)].UTF8String, 1);
            continue;
        }
        if ([t hasPrefix:@"--shack-jit-mb="]) { if (jitMBOut) { int mb = [t substringFromIndex:15].intValue; *jitMBOut = mb >= 16 && mb <= 1024 ? mb : 128; } continue; }
        [a addObject:t];
    }
    if (watchOut) *watchOut = watch;
    // SHACK_CTYPE=<locale> (diagnostic): the process's LC_CTYPE for multibyte conversions. Crimson Desert writes its
    // Korean error messages through wcstombs, which the default C locale turns into blank log lines.
    const char *ctype = getenv("SHACK_CTYPE");
    if (ctype) { const char *got = setlocale(LC_CTYPE, ctype); NSLog(@"[MacShack] LC_CTYPE %s: %s", ctype, got ?: "failed"); }
    return a;
}

NSDictionary *ShackGamePrepareProcess(NSDictionary *launch, NSError **error) {
    // The guest sees its bundle at a standardized path, as on a Mac, where the two agree: directory listings give
    // /private/var/..., which -stringByStandardizingPath turns into /var/... GameMaker's file sandbox compares the two
    // and rejects its own game.ios otherwise ("not in bundle", then a null ini). Host checks use realpath (gGuestRoot).
    NSString *appPath = [launch[@"app"] stringByStandardizingPath], *codeRoot = launch[@"code"], *logs = launch[@"logs"];
    BOOL translate = [launch[@"translate"] boolValue];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *exeName = info[@"CFBundleExecutable"];
    if (![exeName isKindOfClass:NSString.class] || !exeName.length) { if (error) *error = err(@"no CFBundleExecutable in Info.plist"); return nil; }
    NSString *exePath = [appPath stringByAppendingFormat:@"/Contents/MacOS/%@", exeName];
    NSString *codePath = [codeRoot stringByAppendingFormat:@"/Contents/MacOS/%@", exeName];
    // HOME is the container for every game, as on a Mac where all games share ~: engines that build paths from HOME
    // (Godot) and engines that ask NSSearchPath (Unity, Unreal, SDL) land in the same Library, one folder per cloud
    // root.
    NSString *home = launch[@"home"] ?: NSHomeDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("HOME", home.fileSystemRepresentation, 1);
    setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    chdir([appPath stringByAppendingPathComponent:@"Contents/MacOS"].fileSystemRepresentation);
    ShackRedirectOutput([logs stringByAppendingFormat:@"/%@.log", exeName]);
    NSLog(@"[MacShack] launching %@", exePath);
    NSLog(@"[MacShack] code=%@ data=%@", codePath, appPath);
    // Before ShackHooksInstall: it creates the Metal device, and a GPU trace needs MTL_CAPTURE_ENABLED set before that.
    BOOL watchArg = NO; int jitMB = 0, traceSec = 0;
    NSArray *args = ShackGuestArgs(launch[@"argsFile"], &watchArg, &jitMB, &traceSec);
    if (!jitMB) jitMB = translate ? ShackTranslatedJITMB(appPath) : 128;
    NSLog(@"[MacShack] args %@", [args componentsJoinedByString:@" "]);
    if (traceSec) {
        setenv("MTL_CAPTURE_ENABLED", "1", 1);
        NSLog(@"[MacShack] GPU traces enabled%@", traceSec > 0 ? [NSString stringWithFormat:@", one frame in %d s", traceSec] : @"");
        NSString *trace = [logs stringByAppendingFormat:@"/%@.gputrace", exeName];
        if (traceSec > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)traceSec * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ ShackMetalCaptureTrace(trace); });
    }
    if (translate) args = ShackTranslatedArgs(appPath, args);   // before ShackHooksInstall, which reads SHACK_OPENGL
    // GameMaker's Mac runner (its data is game.ios) draws only with OpenGL; it has no Metal path to fall back to.
    if ([NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingPathComponent:@"Contents/Resources/game.ios"]])
        setenv("SHACK_OPENGL", "1", 0);
    ShackHooksInstall(appPath, exePath, codeRoot);
    ShackMetalSetFrameCap([launch[@"fpsCap"] intValue]);
    // File-backed memory tier (ShackSwap.c), opt-in per game (Local Games' Memory swap): Stray ran 27 fps with it and 54
    // without (2026-09-27), so only games that run out of memory want it. Created with no file protection (as Madeira
    // does), so pages can be written back while the phone is locked.
    long swapMB = [launch[@"swapMB"] longValue];
    NSString *swapFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"shack-swap.bin"];
    [NSFileManager.defaultManager removeItemAtPath:swapFile error:nil];
    if (swapMB > 0 && [NSFileManager.defaultManager createFileAtPath:swapFile contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionNone}])
        ShackSwapInit(swapFile.fileSystemRepresentation, (uint64_t)swapMB, (ShackMmapFn)dlsym(RTLD_DEFAULT, "mmap"));   // the real mmap: fishhook leaves dlsym alone
    // Render scale: the backing scale the AppKit shim reports, which games size their drawables from; iOS scales the
    // layer up.
    double renderScale = [launch[@"renderScale"] doubleValue];
    if (renderScale > 0) setenv("SHACK_RENDER_SCALE", [NSString stringWithFormat:@"%g", renderScale].UTF8String, 1);
    // Forced resolution (`displaySize.<Name>`, the tile's long-press menu): a virtual desktop of exactly WxH at scale 1,
    // letterboxed on the phone (shims/ShackDisplay.h). Not overwritten: a game's .args (--shack-env) wins.
    NSString *displaySize = launch[@"displaySize"];
    if (displaySize.length) setenv("SHACK_DISPLAY_SIZE", displaySize.UTF8String, 0);
    // Prime the shim's cached screen metrics on the main thread (libShackAppKit must be loaded: MacShack links it,
    // MacShack Play loads it first).
    [NSClassFromString(@"NSScreen") valueForKey:@"mainScreen"];   // KVC calls +mainScreen
    // ponytail: UE4-only convention, keyed on Contents/UE4/<Project>: the project folder beside Engine, named after
    // the executable in Lies of P but not in Stray (Hk_project, Stray-Mac-Shipping). FMacPlatformProcess::BaseDir()
    // needs Contents/UE4/<Project>/Binaries/Mac to exist (it is empty in shipped games, and the Documents copy drops
    // empty dirs).
    NSString *ueRoot = [appPath stringByAppendingString:@"/Contents/UE4"], *ueProject = nil;
    for (NSString *d in [NSFileManager.defaultManager contentsOfDirectoryAtPath:ueRoot error:nil])
        if (![d isEqualToString:@"Engine"] && (!ueProject || [d isEqualToString:exeName]) &&
            [NSFileManager.defaultManager fileExistsAtPath:[ueRoot stringByAppendingFormat:@"/%@/Content", d]]) ueProject = d;
    NSString *ue4 = [ueRoot stringByAppendingPathComponent:ueProject ?: exeName];
    if (ueProject) {
        [NSFileManager.defaultManager createDirectoryAtPath:[ue4 stringByAppendingString:@"/Binaries/Mac"] withIntermediateDirectories:YES attributes:nil error:nil];
        // UE reads pads through GameController itself; its HID interface would get the same pad a second time from
        // the IOKit shim's virtual gamepad.
        setenv("SHACK_HID_GAMEPAD", "0", 0);
        // UE runs its game on a thread of its own and expects AppKit on the real main thread (the model Lies of P was
        // brought up with); other guests get the Mac model where -run's thread is the app thread.
        setenv("SHACK_APP_THREAD", "main", 0);
    }
    if (ShackWantsXbox2016(appPath)) setenv("SHACK_HID_PAD", "xbox2016", 0);
    // ponytail: UE4-specific, keyed on the MacNoEditor config dir. The engine only creates
    // Library/Application Support/<Company>/<Project>/Saved/Config/MacNoEditor on its first run, so this seeds
    // Engine.ini on the second launch, once, if the engine has not written one. GameUserSettings.ini stays the user's.
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
    for (NSString *company in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:nil]) {
        NSString *cfg = [support stringByAppendingFormat:@"/%@/%@/Saved/Config/MacNoEditor", company, ueProject ?: exeName];
        NSString *engineIni = [cfg stringByAppendingPathComponent:@"Engine.ini"];
        if (![NSFileManager.defaultManager fileExistsAtPath:cfg] || [NSFileManager.defaultManager fileExistsAtPath:engineIni]) continue;
        BOOL ok = [@"[/Script/Engine.RendererSettings]\nr.Streaming.PoolSize=2000\n"
                   writeToFile:engineIni atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[MacShack] first-run config: %@ %@", engineIni, ok ? @"written" : @"FAILED");
    }
    // Connected pads become virtual HID devices before the game's first scan (libShackIOKit, ShackHID.m).
    void (*prewarmPads)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "ShackHIDPrewarm");
    if (prewarmPads) prewarmPads();
    BOOL watch = watchArg || [NSProcessInfo.processInfo.environment[@"SHACK_WATCH"] isEqualToString:@"1"];
    return @{@"exePath": exePath, @"codePath": codePath, @"args": args, @"jitMB": @(jitMB), @"watch": @(watch)};
}
