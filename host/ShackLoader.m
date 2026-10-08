#import "ShackLoader.h"
#import "ShackSteamClient.h"
#import "ShackSteamProbe.h"
#import "ShackHooks.h"
#import "ShackWatch.h"
#import "ShackJIT.h"
#import "ShackMetal.h"
#import "ShackSwap.h"
#import "ShackInstaller.h"
#import "ShackPrep.h"
#import <dlfcn.h>
#import <locale.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#import <sys/mman.h>
#import <unistd.h>
#import <crt_externs.h>

typedef int (*guest_main_t)(int, char **, char **, char **);
extern char **environ;
extern void ShackSetGuestCommandLine(int argc, char **argv);

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
    return ocerz_main(argc, argv);   // runs the guest's main on this thread, as startGuest does
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

static void redirectOutput(NSString *logPath) {
    // The previous run's log survives one relaunch (a crash is usually reported after the game was started again).
    rename(logPath.fileSystemRepresentation, [logPath.stringByDeletingPathExtension stringByAppendingString:@".prev.log"].fileSystemRepresentation);
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IONBF, 0);
}

static BOOL startGuest(NSString *exePath, NSString *argv0, NSArray<NSString *> *args, dispatch_semaphore_t done, int *rcOut, NSError **error) {
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
static NSArray<NSString *> *guestArgs(NSString *path, BOOL *watchOut, int *jitMBOut, int *traceSecOut) {
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
    if (!startGuest(exePath, argv0, nil, dispatch_semaphore_create(0), &rc, error)) return nil;
    return @(rc);
}

+ (BOOL)launchAppAtPath:(NSString *)appPath error:(NSError **)error {
    // The guest sees its bundle at a standardized path, as on a Mac, where the two agree: directory listings give
    // /private/var/..., which -stringByStandardizingPath turns into /var/... GameMaker's file sandbox compares the two
    // and rejects its own game.ios otherwise ("not in bundle", then a null ini). Host checks use realpath (gGuestRoot).
    appPath = appPath.stringByStandardizingPath;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *exeName = info[@"CFBundleExecutable"];
    if (!exeName) { if (error) *error = err(@"no CFBundleExecutable in Info.plist"); return NO; }
    NSString *exePath = [appPath stringByAppendingFormat:@"/Contents/MacOS/%@", exeName];
    if (![self validateAppAtPath:appPath error:error]) return NO;
    NSString *codeRoot = codeRootForApp(appPath, error);
    if (!codeRoot) return NO;
    NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *codePath = [codeRoot stringByAppendingFormat:@"/Contents/MacOS/%@", exeName];
    BOOL needsJIT = [ShackInstaller requiresJITAtAppPath:appPath];
    BOOL translate = [ShackInstaller translatesAtAppPath:appPath];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    // HOME is the container for every game, as on a Mac where all games share ~: engines that build paths from HOME
    // (Godot) and engines that ask NSSearchPath (Unity, Unreal, SDL) land in the same Library, one folder per cloud
    // root.
    NSString *home = NSHomeDirectory();
    NSString *logs = [docs stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("HOME", home.fileSystemRepresentation, 1);
    setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    chdir([appPath stringByAppendingPathComponent:@"Contents/MacOS"].fileSystemRepresentation);
    redirectOutput([logs stringByAppendingFormat:@"/%@.log", exeName]);
    NSLog(@"[MacShack] launching %@", exePath);
    NSLog(@"[MacShack] code=%@ data=%@", codePath, appPath);
    // Before ShackHooksInstall: it creates the Metal device, and a GPU trace needs MTL_CAPTURE_ENABLED set before that.
    BOOL watchArg = NO; int jitMB = 0, traceSec = 0;
    NSArray *args = guestArgs([appPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"args"], &watchArg, &jitMB, &traceSec);
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
    // Frame cap (`-fpsCap.<Name> 30` or `-fpsCap 30` as launch arguments for devicectl runs).
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ShackMetalSetFrameCap(ShackGameFrameCap(name, translate));
    // File-backed memory tier (ShackSwap.c): `swapMB.<Name>`, else `swapMB`, else off (0). Opt-in per game (Local Games'
    // Memory swap): Stray ran 27 fps with it and 54 without (2026-09-27), so only games that run out of memory want it. Created with no
    // file protection (as Madeira does), so pages can be written back while the phone is locked.
    id ownSwap = [defaults objectForKey:[@"swapMB." stringByAppendingString:name]], anySwap = [defaults objectForKey:@"swapMB"];
    long swapMB = ownSwap ? [ownSwap integerValue] : anySwap ? [anySwap integerValue] : 0;   // launch arguments arrive as strings
    NSString *swapFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"shack-swap.bin"];
    [NSFileManager.defaultManager removeItemAtPath:swapFile error:nil];
    if (swapMB > 0 && [NSFileManager.defaultManager createFileAtPath:swapFile contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionNone}])
        ShackSwapInit(swapFile.fileSystemRepresentation, (uint64_t)swapMB, (ShackMmapFn)dlsym(RTLD_DEFAULT, "mmap"));   // the real mmap: fishhook leaves dlsym alone
    // Prime the shim's cached screen metrics on the main thread (the host links libShackAppKit, so the class exists).
    // Render scale: the backing scale the AppKit shim reports, which games size their drawables from; iOS scales the
    // layer up.
    double renderScale = ShackGameRenderScale(name, translate);
    if (renderScale > 0) setenv("SHACK_RENDER_SCALE", [NSString stringWithFormat:@"%g", renderScale].UTF8String, 1);
    // Forced resolution (`displaySize.<Name>`, the tile's long-press menu): a virtual desktop of exactly WxH at scale 1,
    // letterboxed on the phone (shims/ShackDisplay.h). Not overwritten: a game's .args (--shack-env) wins.
    NSString *displaySize = [defaults stringForKey:[@"displaySize." stringByAppendingString:name]];
    if (displaySize.length) setenv("SHACK_DISPLAY_SIZE", displaySize.UTF8String, 0);
    [NSClassFromString(@"NSScreen") valueForKey:@"mainScreen"];   // KVC calls +mainScreen
    // Hooks are installed and point at this guest: a failed launch is terminal for this process.
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
    // Mono guest (Unity): the patched runtime needs one debugger-prepared RX pool with an RW alias before its
    // first code allocation. ponytail: keyed on the dylib's presence; the prepare costs one debugger round-trip
    // per 16 KB page (two per round trip for a debugger-allocated pool), so the default is 128 MB (512-1024 for x86), raise with --shack-jit-mb=N in the
    // .args if Mono logs exhaustion.
    BOOL watch = watchArg || [NSProcessInfo.processInfo.environment[@"SHACK_WATCH"] isEqualToString:@"1"];
    // Connected pads become virtual HID devices before the game's first scan (libShackIOKit, ShackHID.m).
    void (*prewarmPads)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "ShackHIDPrewarm");
    if (prewarmPads) prewarmPads();
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
            BOOL started = translate ? startTranslated(exePath, args, &e) : startGuest(codePath, exePath, args, nil, NULL, &e);
            if (!started) reportLaunchFailure([e.localizedDescription stringByAppendingString:@" Close and reopen MacShack to retry."]);
        });
        return YES;
    }
    ShackWatchStart(watch);
    if (startGuest(codePath, exePath, args, nil, NULL, error)) return YES;
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
    redirectOutput([logs stringByAppendingPathComponent:@"steam_osx.log"]);
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
    ShackSteamPrepareHelperFiles();   // private images a newer MacShack added (steamclient_h, steamclient_g)
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
    return startGuest(codePath, exePath, args, nil, NULL, error);
}
@end
