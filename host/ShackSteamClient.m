// The macOS Steam client's process layer on iOS (Mac original prep/steam-onehost/onehost.m).
// steam_osx starts its Chromium UI, Steam Helper, with tier0's CreateSimpleProcess (fork + exec, which iOS forbids):
// here it runs in-process instead, on the UIKit main thread (CEF insists on the real main thread), under a fake pid that
// kill/waitid/waitpid answer for. Chromium runs in one process with V8's interpreter (no JIT) and is told where its
// framework and bundle are; the helper's images see the helper's own argv.
#import "ShackSteamClient.h"
#import "ShackLoader.h"
#import <IOSurface/IOSurfaceRef.h>
#import <UIKit/UIKit.h>
#import "ShackHooks.h"
#import "ShackInstaller.h"
#import "ShackJIT.h"
#import "ShackJITHelper.h"
#import <objc/message.h>
#import <pthread.h>
#import <spawn.h>
#import <sys/event.h>
#import "ShackSteamProbe.h"
#import "vendor/fishhook.h"
#import <crt_externs.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <stdatomic.h>
#import <sys/wait.h>

typedef int (*guest_main_t)(int, char **, char **, char **);
enum { kHelperPid = 1000001, kGamePid = 1000002 };
void ShackCVSleepLinksOf(const char *image);   // libShackCV
void ShackAppKitRestoreAppLoop(void);   // libShackAppKit
void ShackHIDForgetSecondGuest(void);   // libShackIOKit
void ShackHIDSetXbox2016(BOOL on);
void ShackHIDSetSecondGuestTest(BOOL (*isSecond)(const void *pc));   // macOS and iOS pids stay below 100000: never a real process
static NSString *gBundle, *gCode;
static volatile int gHelperState;   // 0 not started, 1 running, 2 ended
static int gHelperArgc, gHelperStatus;
static char **gHelperArgv;
// A game Steam started, running in this process (below): its stand-in process.
static struct { volatile int state; int status, argc, kq; char **argv, **envp; pthread_t thread; id delegate; NSString *app; char code[PATH_MAX]; int jitMB; BOOL translated; } gGame = { .kq = -1 };
NSString *ShackSteamClientGameName(void) { return gGame.state == 1 ? gGame.app.lastPathComponent.stringByDeletingPathExtension : nil; }   // the island menu's game
static pid_t (*origCreateSimpleProcess)(void *, uint32_t, char **, const char *);
static int (*origKill)(pid_t, int);
static int (*origWaitid)(idtype_t, id_t, siginfo_t *, int);
static pid_t (*origWaitpid)(pid_t, int *, int);
static int *(*origGetArgc)(void);
static char ***(*origGetArgv)(void);

static void say(NSString *line) {
    NSLog(@"[SteamClient] %@", line);
}

// The images that make up the helper "process": itself, Chromium, its private tier0/vstdlib/SDL3.
static BOOL callerIsHelper(const void *ra) {
    Dl_info info;
    if (gHelperState == 0 || !dladdr(ra, &info) || !info.dli_fname) return NO;
    NSString *name = @(info.dli_fname).lastPathComponent;
    return [name isEqualToString:@"Steam Helper.helper"] || [name isEqualToString:@"Chromium Embedded Framework"] ||
           [name isEqualToString:@"libtier0_h.dylib"] || [name isEqualToString:@"libvstdlib_h.dylib"] || [name isEqualToString:@"libSDLh.dylib"];
}
static int *steamGetArgc(void) {
    const void *ra = __builtin_return_address(0);
    return callerIsHelper(ra) ? &gHelperArgc : gGame.state && ShackHooksIsSecondCaller(ra) ? &gGame.argc : origGetArgc();
}
static char ***steamGetArgv(void) {
    const void *ra = __builtin_return_address(0);
    return callerIsHelper(ra) ? &gHelperArgv : gGame.state && ShackHooksIsSecondCaller(ra) ? &gGame.argv : origGetArgv();
}

static int steamKill(pid_t pid, int sig) {
    if (pid == kGamePid) {
        if (sig) say([NSString stringWithFormat:@"kill(game, %d): ignored, a game in this process quits from its own menu", sig]);
        if (gGame.state != 1) { errno = ESRCH; return -1; }
        return 0;
    }
    if (pid != kHelperPid) return origKill(pid, sig);
    if (sig) say([NSString stringWithFormat:@"kill(Steam Helper, %d): ignored", sig]);
    if (gHelperState != 1) { errno = ESRCH; return -1; }
    return 0;
}
static int steamWaitid(idtype_t type, id_t id, siginfo_t *info, int options) {
    if (type == P_PID && id == kGamePid) {
        while (gGame.state == 1 && !(options & WNOHANG)) sleep(1);
        if (info) memset(info, 0, sizeof *info);   // si_pid 0: still running
        if (gGame.state == 2 && info) { info->si_pid = kGamePid; info->si_code = CLD_EXITED; info->si_status = gGame.status; }
        return 0;
    }
    if (type != P_PID || id != kHelperPid) return origWaitid(type, id, info, options);
    while (gHelperState == 1 && !(options & WNOHANG)) sleep(1);
    if (info) memset(info, 0, sizeof *info);   // si_pid 0: still running
    if (gHelperState == 2 && info) { info->si_pid = kHelperPid; info->si_code = CLD_EXITED; info->si_status = gHelperStatus; }
    return 0;
}
static pid_t steamWaitpid(pid_t pid, int *status, int options) {
    if (pid == kGamePid) {
        while (gGame.state == 1 && !(options & WNOHANG)) sleep(1);
        if (gGame.state == 1) return 0;
        if (status) *status = W_EXITCODE(gGame.status, 0);
        return pid;
    }
    if (pid != kHelperPid) return origWaitpid(pid, status, options);
    if (gHelperState == 1) return 0;
    if (status) *status = W_EXITCODE(gHelperStatus, 0);
    return pid;
}

// Steam Helper's windows (CBrowserComposerSystem::CreateOutputWindow, flags hidden|borderless) get SDL's macOS default
// backend, OpenGL, which iOS lacks: creation fails loading libGL. They draw with SDL's software renderer on the window
// surface, which SDL presents with a renderer of its own: asked for Metal, the window gets no OpenGL default.
// Rebound in the helper's image only, against its private SDL (libSDLh): an SDL property ID means nothing to the other.
static void *(*helperCreateWindow)(uint32_t props);
static int64_t (*helperGetNumber)(uint32_t props, const char *name, int64_t fallback);
static bool (*helperSetNumber)(uint32_t props, const char *name, int64_t value);
static void *helperCreateWindowWithProperties(uint32_t props) {
    int64_t flags = helperGetNumber(props, "SDL.window.create.flags", 0);
    helperSetNumber(props, "SDL.window.create.flags", (flags & ~(int64_t)0x2) | 0x20000000);   // -SDL_WINDOW_OPENGL +SDL_WINDOW_METAL
    void *window = helperCreateWindow(props);
    say([NSString stringWithFormat:@"Steam Helper window, SDL flags 0x%llx, on Metal: %@", flags, window ? @"created" : @"FAILED"]);
    return window;
}

// A program's private steamclient (steamclient_<letter>, prepared beside steam_osx's) loaded with load, its imports
// rebound to the program's own answers (pid; a game's environment too). NULL when it is not prepared.
static void *loadPrivateSteamclient(void *(*load)(const char *, int), int mode, char letter, struct rebinding *r, size_t n) {
    NSString *name = [NSString stringWithFormat:@"steamclient_%c.dylib", letter];
    void *handle = load([gCode stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:name]].fileSystemRepresentation, mode);
    for (uint32_t i = 0; handle && n && i < _dyld_image_count(); i++)
        if ([@(_dyld_get_image_name(i)).lastPathComponent isEqualToString:name])
            rebind_symbols_image((void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), r, n);
    return handle;
}
static BOOL isSteamclientPath(const char *path) {
    const char *base = path ? strrchr(path, '/') : NULL;
    return base && !strcmp(base, "/steamclient.dylib");
}

// Steam Helper's own Steam API (linked into it) loads steamclient as a separate process would. steam_osx's steamclient,
// the same globals, failed its init (IPC names collide, one pid) and its cleanup's BShutdownIfAllPipesClosed shut down
// steam_osx's file writer (the sign-in in local.vdf was never saved again). It gets a private copy, steamclient_h,
// that knows itself as the helper's pid: SteamClient.Input's controller messages to Big Picture come through it.
// Without the copy (a Steam prepared before it) the helper goes without, as when its Steam API cannot start.
// Its "File exists" opens and "pid ... != 1000001, clearing client_port" are Steam's create-or-open and re-connect, not
// failures: it connects, Big Picture navigates with a pad, and Steam's config still saves (phone, 10-03).
static void *(*helperOrigDlopen)(const char *, int);
static pid_t helperPid(void) { return kHelperPid; }
static void *helperDlopen(const char *path, int mode) {
    if (isSteamclientPath(path)) {
        void *handle = loadPrivateSteamclient(helperOrigDlopen, mode, 'h',
            (struct rebinding[]){{"getpid", helperPid, NULL}, {"ThreadGetCurrentProcessId", helperPid, NULL}}, 2);
        static dispatch_once_t once;   // it retries every second when refused: said once
        dispatch_once(&once, ^{ say(handle ? @"Steam Helper's Steam API: its own steamclient_h" : @"Steam Helper's Steam API: no steamclient_h, refused"); });
        return handle;
    }
    return helperOrigDlopen(path, mode);
}

// The helper image's own rebindings (above), applied once it is loaded.
static void rebindHelper(const struct mach_header_64 *h, intptr_t slide) {
    void *sdl = dlopen([gCode stringByAppendingPathComponent:@"Contents/MacOS/libSDLh.dylib"].fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
    helperGetNumber = sdl ? dlsym(sdl, "SDL_GetNumberProperty") : NULL;
    helperSetNumber = sdl ? dlsym(sdl, "SDL_SetNumberProperty") : NULL;
    helperCreateWindow = sdl ? dlsym(sdl, "SDL_CreateWindowWithProperties") : NULL;
    if (helperGetNumber && helperSetNumber && helperCreateWindow)
        rebind_symbols_image((void *)h, slide, (struct rebinding[]){{"SDL_CreateWindowWithProperties", helperCreateWindowWithProperties, NULL}}, 1);
    else say(@"Steam Helper: libSDLh not found, its windows keep asking for OpenGL");
    rebind_symbols_image((void *)h, slide, (struct rebinding[]){{"dlopen", helperDlopen, (void **)&helperOrigDlopen}}, 1);
}

// Loads a program image and finds its main (LC_MAIN); loaded(header, slide) runs before main is returned.
static guest_main_t loadMain(NSString *path, NSString **error, void (*loaded)(const struct mach_header_64 *, intptr_t)) {
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) { *error = @(dlerror()); return NULL; }
    char want[PATH_MAX], have[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, want)) { *error = @"no such file"; return NULL; }
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!realpath(_dyld_get_image_name(i), have) || strcmp(have, want)) continue;
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        if (loaded) loaded(h, _dyld_get_image_vmaddr_slide(i));
        const struct load_command *lc = (const void *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize))
            if (lc->cmd == LC_MAIN) return (guest_main_t)((const char *)h + ((const struct entry_point_command *)lc)->entryoff);
    }
    *error = @"loaded but no LC_MAIN";
    return NULL;
}

// GET http://127.0.0.1:8080/json over a plain socket (App Transport Security would refuse an NSURL load of plain HTTP).
// The JSON body, or nil with why in *why.
static NSData *devToolsList(NSString **why) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    struct timeval t = { 5, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a)) {
        *why = [NSString stringWithFormat:@"connect: %s", strerror(errno)];
        if (fd >= 0) close(fd);
        return nil;
    }
    const char req[] = "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n";   // Chromium refuses HTTP/1.0
    write(fd, req, sizeof req - 1);
    NSMutableData *reply = [NSMutableData data];
    char buf[16384];
    for (ssize_t n; (n = read(fd, buf, sizeof buf)) > 0;) [reply appendBytes:buf length:(NSUInteger)n];
    close(fd);
    NSRange end = [reply rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, reply.length)];
    if (end.location == NSNotFound) {
        *why = [NSString stringWithFormat:@"%lu bytes, no HTTP header end: %@", (unsigned long)reply.length,
                [[NSString alloc] initWithData:[reply subdataWithRange:NSMakeRange(0, MIN(reply.length, 120))] encoding:NSUTF8StringEncoding]];
        return nil;
    }
    return [reply subdataWithRange:NSMakeRange(NSMaxRange(end), reply.length - NSMaxRange(end))];
}

// Runtime.evaluate of one expression in a DevTools target (its webSocketDebuggerUrl path), over a minimal WebSocket:
// the upgrade, one masked text frame out, frames in until the reply to id 1. The JSON reply, or why not.
static NSString *devToolsEvaluate(NSString *wsPath, NSString *expression) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(8080), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    struct timeval t = { 8, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof t);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a)) { if (fd >= 0) close(fd); return @"(connect failed)"; }
    NSString *upgrade = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         "Sec-WebSocket-Key: c3RlYW1jbGllbnRwcm9iZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", wsPath];
    write(fd, upgrade.UTF8String, strlen(upgrade.UTF8String));
    char buf[65536];
    ssize_t n = read(fd, buf, sizeof buf);   // the 101 response (assumed to arrive alone)
    if (n <= 0 || !strstr(buf, " 101 ")) { close(fd); return @"(no WebSocket upgrade)"; }
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"id": @1, @"method": @"Runtime.evaluate",
        @"params": @{@"expression": expression, @"returnByValue": @YES, @"awaitPromise": @YES}} options:0 error:nil];
    NSMutableData *frame = [NSMutableData dataWithBytes:(uint8_t[]){0x81} length:1];
    uint8_t mask[4] = {1, 2, 3, 4};
    if (body.length < 126) [frame appendBytes:(uint8_t[]){0x80 | (uint8_t)body.length} length:1];
    else [frame appendBytes:(uint8_t[]){0x80 | 126, (uint8_t)(body.length >> 8), (uint8_t)body.length} length:3];
    [frame appendBytes:mask length:4];
    const uint8_t *b = body.bytes;
    for (NSUInteger i = 0; i < body.length; i++) { uint8_t c = b[i] ^ mask[i % 4]; [frame appendBytes:&c length:1]; }
    write(fd, frame.bytes, frame.length);
    NSMutableData *in = [NSMutableData data];
    NSString *reply = @"(no reply in 8 s: the page's thread is busy or waiting)";
    while ((n = read(fd, buf, sizeof buf)) > 0) {
        [in appendBytes:buf length:(NSUInteger)n];
        for (;;) {   // whole server frames (unmasked) at the front of `in`
            const uint8_t *f = in.bytes; NSUInteger have = in.length, hdr = 2, len;
            if (have < 2) break;
            len = f[1] & 0x7f;
            if (len == 126) { if (have < 4) break; len = (NSUInteger)f[2] << 8 | f[3]; hdr = 4; }
            else if (len == 127) { if (have < 10) break; len = 0; for (int i = 2; i < 10; i++) len = len << 8 | f[i]; hdr = 10; }
            if (have < hdr + len) break;
            NSString *text = [[NSString alloc] initWithData:[in subdataWithRange:NSMakeRange(hdr, len)] encoding:NSUTF8StringEncoding];
            [in replaceBytesInRange:NSMakeRange(0, hdr + len) withBytes:NULL length:0];
            if ([text hasPrefix:@"{\"id\":1,"]) { close(fd); return text; }
        }
    }
    close(fd);
    return reply;
}

// The layer tree on the screen (diagnostic): what each layer is, where, and what it shows.
static void dumpLayers(CALayer *l, int depth, NSMutableString *out) {
    id c = l.contents;
    [out appendFormat:@"\n%*s%@ %@%@ opacity %.2f contents %@%@", depth * 2, "", NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
        l.hidden ? @" HIDDEN" : @"", l.opacity, c ? NSStringFromClass([c class]) : @"-", l.delegate ? [@" view " stringByAppendingString:NSStringFromClass([l.delegate class])] : @""];
    if (c && CFGetTypeID((__bridge CFTypeRef)c) == IOSurfaceGetTypeID()) {   // a few pixels: is Chromium's frame drawn?
        IOSurfaceRef surface = (__bridge IOSurfaceRef)c;
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface), row = IOSurfaceGetBytesPerRow(surface);
        const uint8_t *base = IOSurfaceGetBaseAddress(surface);
        [out appendFormat:@" %zux%zu '%.4s'", w, h, (const char *)&(uint32_t){CFSwapInt32HostToBig(IOSurfaceGetPixelFormat(surface))}];
        for (int i = 1; i <= 3 && base; i++) { const uint8_t *p = base + (h * i / 4) * row + (w * i / 4) * 4; [out appendFormat:@" %02x%02x%02x%02x", p[0], p[1], p[2], p[3]]; }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    for (CALayer *s in l.sublayers) dumpLayers(s, depth + 1, out);
}

// Pad input as Steam's own SDL (libSDL3) delivers it to event watches like Steam's: hats, buttons, devices of joysticks
// (0x602-0x606) and gamepads (0x651-0x655). Diagnostics (-cef-enable-debugging).
static bool logSDLEvent(void *userdata, const uint32_t *e) {
    static _Atomic int n;
    if (((e[0] >= 0x602 && e[0] <= 0x606) || (e[0] >= 0x651 && e[0] <= 0x655)) && n++ < 60)
        fprintf(stderr, "[MacShack] Steam SDL event %#x which %u part %u value %u\n", e[0], e[4], ((const uint8_t *)e)[20], ((const uint8_t *)e)[21]);
    return true;
}

// What Chromium serves on its DevTools port (-cef-enable-debugging), logged from inside the app: the phone's loopback
// is not reachable from the Mac. Each page's title and URL; SharedJSContext at /routes/library/home = Steam's UI is up.
static void logDevToolsPages(void) {
    NSString *log = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs/steam-cdp.log"];
    [@"" writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 60; i++) {   // 5 minutes
            sleep(5);
            static bool watching;
            if (!watching) {
                void *sdl = dlopen([gCode stringByAppendingPathComponent:@"Contents/MacOS/libSDL3.dylib"].fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
                bool (*addWatch)(void *, void *) = sdl ? dlsym(sdl, "SDL_AddEventWatch") : NULL;
                if (addWatch && (watching = addWatch(logSDLEvent, NULL))) fprintf(stderr, "[MacShack] watching Steam's SDL pad events\n");
            }
            NSString *why = nil;
            NSData *data = devToolsList(&why);
            NSArray *pages = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (data && !pages) why = [NSString stringWithFormat:@"not JSON: %@", [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 120))] encoding:NSUTF8StringEncoding]];
            // Which kinds of work the main thread still services (Chromium's UI thread is the main thread).
            static volatile int blocks, queue, timers;
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ blocks++; });
            CFRunLoopWakeUp(CFRunLoopGetMain());
            dispatch_async(dispatch_get_main_queue(), ^{ queue++; });
            CFRunLoopAddTimer(CFRunLoopGetMain(), CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent(), 0, 0, 0, ^(CFRunLoopTimerRef t) { timers++; }), kCFRunLoopCommonModes);
            NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@ [main thread served: blocks %d queue %d timers %d]", NSDate.date,
                                     pages ? [NSString stringWithFormat:@"%lu pages", (unsigned long)pages.count] : why, blocks, queue, timers];
            for (NSDictionary *p in [pages isKindOfClass:NSArray.class] ? pages : @[]) {
                [line appendFormat:@"\n  %@ | %@", p[@"title"], p[@"url"]];
                NSString *ws = p[@"webSocketDebuggerUrl"];   // ws://127.0.0.1:8080/devtools/page/<id>
                NSRange path = [ws rangeOfString:@"/devtools/"];
                // The expression: Documents/Logs/steam-cdp.js when present (copied over from the Mac, no rebuild), else the page's state.
                NSString *js = [NSString stringWithContentsOfFile:[log.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"steam-cdp.js"] encoding:NSUTF8StringEncoding error:nil]
                    ?: @"JSON.stringify({ready: document.readyState, title: document.title, html: document.documentElement.outerHTML.slice(0, 600), "
                       "resources: performance.getEntriesByType('resource').map(e => e.name.split('/').pop().slice(0, 40) + ' ' + Math.round(e.duration) + 'ms')})";
                if (path.location != NSNotFound)
                    [line appendFormat:@"\n    %@", devToolsEvaluate([ws substringFromIndex:path.location], js)];
            }
            if (i == 3) dispatch_sync(dispatch_get_main_queue(), ^{
                for (UIWindow *w in ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows) dumpLayers(w.layer, 1, line);
            });
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:log];
            [h seekToEndOfFile];
            [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    });
}

static BOOL isHelperBrowser(char *const argv[]) {
    if (!argv || !argv[0] || strcmp(@(argv[0]).lastPathComponent.UTF8String, "Steam Helper")) return NO;
    for (int i = 1; argv[i]; i++) if (!strncmp(argv[i], "--type=", 7)) return NO;
    return YES;
}

static pid_t startHelper(char *const argv[], char *const envp[]) {
    if (gHelperState) { say(@"Steam Helper already started once in this process; refusing another"); return 0; }
    NSString *framework = [gBundle stringByAppendingPathComponent:@"Contents/MacOS/Frameworks/Chromium Embedded Framework.framework"];
    // CEF reads its main bundle's Info.plist, and turns crashpad on when Resources/crash_reporter.cfg is there. iOS lets
    // it start no crashpad_handler, so it snapshotted the whole process in-process at every non-fatal NOTREACHED and its
    // log grew by a GB in minutes: the main bundle it gets is a copy of Steam Helper.app's Info.plist alone.
    NSString *helperApp = [gCode stringByAppendingPathComponent:@"Contents/MacOS/Frameworks/Steam Helper.app"];
    [NSFileManager.defaultManager createDirectoryAtPath:[helperApp stringByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[helperApp stringByAppendingPathComponent:@"Contents/Info.plist"] error:nil];
    [NSFileManager.defaultManager copyItemAtPath:[gBundle stringByAppendingPathComponent:@"Contents/MacOS/Frameworks/Steam Helper.app/Contents/Info.plist"]
                                          toPath:[helperApp stringByAppendingPathComponent:@"Contents/Info.plist"] error:nil];
    // Chromium's log in MacShack's own Logs, one per launch (Steam's --log-file appends to its cef_log.txt forever).
    NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
    NSString *cefLog = [logs stringByAppendingPathComponent:@"cef.log"];
    rename(cefLog.fileSystemRepresentation, [logs stringByAppendingPathComponent:@"cef.prev.log"].fileSystemRepresentation);
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 0; argv[i]; i++) [args addObject:@(argv[i])];
    // The last of a repeated switch wins, so these override Steam's own --log-file.
    [args addObjectsFromArray:@[@"--single-process", @"--js-flags=--jitless", @"--no-sandbox", @"--disable-breakpad",
                                @"--disable-software-rasterizer",   // no SwiftShader: it needs JIT, and its failing retries hit NOTREACHED
                                [@"--framework-dir-path=" stringByAppendingString:framework],
                                [@"--main-bundle-path=" stringByAppendingString:helperApp],
                                [@"--log-file=" stringByAppendingString:cefLog]]];
    // GPU (when Steam was not started with -cef-disable-gpu): ANGLE on Metal in-process, frames handed over as IOSurfaces;
    // the remote-layer path (CAContext contextWithCGSConnection:, CALayerHost) is macOS WindowServer API.
    [args addObject:@"--use-angle=metal"];
    NSUInteger features = [args indexOfObjectPassingTest:^BOOL(NSString *a, NSUInteger i, BOOL *stop) { return [a hasPrefix:@"--disable-features="]; }];
    if (features == NSNotFound) [args addObject:@"--disable-features=RemoteCoreAnimationAPI"];
    else args[features] = [args[features] stringByAppendingString:@",RemoteCoreAnimationAPI"];   // one switch: the last would win
    gHelperArgc = (int)args.count;
    gHelperArgv = calloc(args.count + 1, sizeof *gHelperArgv);   // lives for the process
    for (NSUInteger i = 0; i < args.count; i++) gHelperArgv[i] = strdup(args[i].UTF8String);
    int envc = 0;
    while (envp && envp[envc]) envc++;
    char **env = calloc((size_t)envc + 1, sizeof *env);
    for (int i = 0; i < envc; i++) env[i] = strdup(envp[i]);
    say([@"Steam Helper in-process: " stringByAppendingString:[args componentsJoinedByString:@" "]]);
    gHelperState = 1;
    if ([args containsObject:@"--remote-debugging-port=8080"]) logDevToolsPages();   // -cef-enable-debugging (diagnostics)
    NSString *code = [gCode stringByAppendingPathComponent:@"Contents/MacOS/Steam Helper.helper"];
    // From a main run-loop block, not the main dispatch queue: Chromium's loop never returns, and while a main-queue
    // block runs the main queue drains nothing else, so every later hop to main (steam_osx hiding its bootstrapper
    // window) would wait forever. Nested run-loop passes inside a run-loop block still drain it.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        NSString *error = nil;
        guest_main_t entry = loadMain(code, &error, rebindHelper);
        if (!entry) { say([@"Steam Helper did not load: " stringByAppendingString:error]); gHelperStatus = 127; gHelperState = 2; return; }
        say(@"calling Steam Helper main on the main thread");
        gHelperStatus = entry(gHelperArgc, gHelperArgv, env, NULL);
        say([NSString stringWithFormat:@"Steam Helper main returned %d", gHelperStatus]);
        gHelperState = 2;
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    return kHelperPid;
}

// tier0's process API: a process handle is its pid. Flags 0x8 execv(argv) and 0x10 execvp(argv) carry an argv.
static pid_t steamCreateSimpleProcess(void *argvOrCommand, uint32_t flags, char **envp, const char *cwd) {
    if ((flags & 0x18) && isHelperBrowser(argvOrCommand)) return startHelper(argvOrCommand, envp ? envp : *_NSGetEnviron());
    return origCreateSimpleProcess(argvOrCommand, flags, envp, cwd);   // its fork fails cleanly (libShackSteamClient)
}

// --- games Steam starts ---
// steamclient starts a Mac game with posix_spawn of its executable (TetherGeist) or an app bundle with NSWorkspace
// (Mina). A game in Steam's steamapps/common runs in this process instead: prepared and signed where Steam keeps it
// (ShackInstaller), its main on a thread of its own under a stand-in pid, its code seeing its own bundle, executable and
// argv (ShackHooksAddGuest) and environment (below). Steam watches the pid (kevent EVFILT_PROC, waitpid, kill) and hears
// it exit when the game quits; the game's windows then leave the screen.
// ponytail: one game per MacShack run (images cannot be unloaded).
void ShackAppKitOrderOutWindowsOfThread(pthread_t thread);   // libShackAppKit
static int (*origKevent)(int, const struct kevent *, int, struct kevent *, int, const struct timespec *);

static void gameEnded(int status) {
    if (gGame.state != 1) return;
    gGame.status = status; gGame.state = 2;
    say([NSString stringWithFormat:@"game ended (%d): back to Steam", status]);
    void (*stopAudio)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "ShackAudioStopAll");   // its sounds would play on
    if (stopAudio) stopAudio();
    // Steam's again: its app thread (events, its own pump), the pads without the game's callbacks (its code stays loaded
    // but is torn down), its frame cap and render scale, its display links awake before its window has the screen.
    ShackAppKitRestoreAppLoop();
    ShackHIDForgetSecondGuest();
    ShackHIDSetXbox2016(NO);   // Steam's own identity again
    ShackMetalSetFrameCap(ShackSteamUIFrameCap());
    ShackAppKitSetRenderScale(ShackSteamUIRenderScale());
    ShackCVSleepLinksOf(NULL);
    ShackAppKitOrderOutWindowsOfThread(gGame.thread);
    id app = [NSClassFromString(@"NSApplication") valueForKey:@"sharedApplication"];
    if (gGame.delegate) [app setValue:gGame.delegate forKey:@"delegate"];   // Steam's, which the game's nib replaced
    if (gGame.kq >= 0) {
        struct kevent ev;
        EV_SET(&ev, kGamePid, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
        origKevent(gGame.kq, &ev, 1, NULL, 0, NULL);
    }
}

static char **cStrings(NSArray<NSString *> *list) {
    char **out = calloc(list.count + 1, sizeof *out);   // lives for the process
    for (NSUInteger i = 0; i < list.count; i++) out[i] = strdup(list[i].UTF8String);
    return out;
}
static char **copyStrings(char *const list[], int *count) {
    int n = 0;
    while (list && list[n]) n++;
    char **out = calloc((size_t)n + 1, sizeof *out);   // lives for the process
    for (int i = 0; i < n; i++) out[i] = strdup(list[i]);
    if (count) *count = n;
    return out;
}

static void *gameThread(void *arg) {
    NSString *exe = CFBridgingRelease(arg);
    pthread_setname_np("game-main");
    ShackHooksAdoptGuestThread();
    {   // diagnostic: pthread keys left for the game (iOS allows 512 per process; Steam's own come from SteamTSD.c)
        pthread_key_t keys[600]; int n = 0;
        while (n < 600 && pthread_key_create(&keys[n], NULL) == 0) n++;
        for (int i = 0; i < n; i++) pthread_key_delete(keys[i]);
        say([NSString stringWithFormat:@"pthread keys free for the game: %d", n]);
    }
    // A Unity Mono game (its install record says requiresJIT) runs its compiled code from a pool the JIT helper
    // prepares, as when MacShack's own list launches it (ShackLoader, AppModel.startJITHelper); without it iOS kills
    // the process at Mono's first method (Okko, 10-03). Waited for on this thread only: Steam and its UI run on.
    if (gGame.jitMB) {
        NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
        if ([NSFileManager.defaultManager fileExistsAtPath:ShackJITPairingFileURL().path]) {
            say(@"the game needs JIT: starting the JIT helper (keep LocalDevVPN on and the phone unlocked)");
            dispatch_async(dispatch_get_main_queue(), ^{
                ShackJITHelperStart(^(BOOL ok, NSString *log) {
                    [log writeToFile:[logs stringByAppendingPathComponent:@"jit-helper.log"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    if (!ok) say([@"JIT helper failed: " stringByAppendingString:[log componentsSeparatedByString:@"\n"].lastObject ?: @"?"]);
                });
            });
        } else say(@"the game needs JIT and there is no pairing file: run the MacShack script in StikDebug (Enable Script)");
        if (!ShackJITPoolSetup((size_t)gGame.jitMB << 20)) { say(@"JIT setup failed: the game does not start (see jit-helper.log)"); gameEnded(126); return NULL; }
        say(@"JIT pool ready");
    }
    if (gGame.translated) {   // an Intel game: AArchX translates its executable, here Steam's own file
        say(@"calling the game's main under AArchX");
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < gGame.argc; i++) [args addObject:@(gGame.argv[i])];
        gameEnded(ShackRunTranslated(exe, args));
        return NULL;
    }
    NSString *error = nil;
    guest_main_t entry = loadMain(exe, &error, NULL);
    if (!entry) { say([@"the game did not load: " stringByAppendingString:error]); gameEnded(127); return NULL; }
    say(@"calling the game's main");
    gameEnded(entry(gGame.argc, gGame.argv, gGame.envp, NULL));   // main returned (exit ends it in the hooks)
    return NULL;
}

// The bundle that holds path, when path is a game's executable in Steam's library; else nil. Some Mac depots are the
// bundle itself (steamapps/common/<Game>/Contents/MacOS/..., no .app: Super Money Ring), which macOS runs as well.
static NSString *steamGameApp(const char *path) {
    NSString *p = @(path);
    NSRange common = [p rangeOfString:@"/steamapps/common/" options:NSCaseInsensitiveSearch];
    NSRange bundle = [p rangeOfString:@"/Contents/MacOS/"];
    return common.location != NSNotFound && bundle.location != NSNotFound && bundle.location > NSMaxRange(common)
        ? [p substringToIndex:bundle.location] : nil;
}

// The game's own Steam client API. Valve's libsteam_api in the game finds Steam through ipcserver's Mach service (here
// libShackSteamClient's bootstrap_look_up, which Steam's images bind to and a game's do not), reads SteamAppId and its
// friends from the environment (Steam passes them to the game alone) and loads steamclient: a private copy, as the
// helper's, steamclient_g with the game's pid and environment (the Mac prototype's steamclient_g: Mina's SteamAPI_Init OK).
static pid_t gamePid(void) { return kGamePid; }
static char *(*realGetenv)(const char *);
// ponytail: Steam's variables are read from the launch's copy, so a game's own setenv of one of them goes unseen.
static char *gameGetenv(const char *name) {
    size_t n = strlen(name);
    char *value = NULL;
    for (char **e = gGame.envp; e && *e && !value; e++) if (!strncmp(*e, name, n) && (*e)[n] == '=') value = *e + n + 1;
    static _Atomic int traced;   // diagnostic: the first Steam names asked (no values: some are tokens)
    if (!strncmp(name, "Steam", 5) && traced++ < 40) fprintf(stderr, "[SteamClient] the game's getenv %s: %s\n", name, value ? "Steam's launch" : "process");
    return value ?: realGetenv(name);
}
static void *(*gameOrigDlopen)(const char *, int);   // ShackHooks' (each game image's dlopen as it loaded)
static void *gameDlopen(const char *path, int mode) {
    if (!isSteamclientPath(path)) return gameOrigDlopen(path, mode);
    void *handle = loadPrivateSteamclient(gameOrigDlopen, mode, 'g', NULL, 0);   // its answers: gameImageAdded
    say(handle ? @"the game's Steam API: its own steamclient_g" : [@"the game's Steam API: steamclient_g did not load: " stringByAppendingString:@(dlerror() ?: "not prepared")]);
    return handle;
}
// The game's SteamAPI_Init outcome and Valve's message for it, in the log (ESteamAPIInitResult: 0 OK, 1 failed
// generic, 2 no Steam client, 3 version mismatch).
static int (*realSteamInit)(const char *, char *);
static int gameSteamInit(const char *versions, char *message) {
    char mine[1024] = "";
    int result = realSteamInit(versions, message ?: mine);
    say([NSString stringWithFormat:@"the game's SteamAPI_Init: %d %s", result, message ?: mine]);
    return result;
}
// Diagnostic: the type and origin of the first C++ exceptions the game's code throws (Okko's libGalaxy threw
// boost::system::system_error "tss" in a static initializer: dyld's "c++ exception thrown in static initializer").
// No what(): through multiple inheritance (boost::wrapexcept) the guessed vtable slot is another function.
static void (*realCxaThrow)(void *, void *, void (*)(void *));
static void gameCxaThrow(void *exception, void *type, void (*destructor)(void *)) {
    static _Atomic int thrown;
    if (thrown++ < 20) {
        const char *name = type ? ((const char *const *)type)[1] : "?";   // std::type_info: vtable, then its name
        Dl_info info; const void *ra = __builtin_return_address(0);
        BOOL found = dladdr(ra, &info) && info.dli_fname;
        fprintf(stderr, "[SteamClient] the game throws %s from %s+%#lx (%s)\n", name, found ? strrchr(info.dli_fname, '/') + 1 : "?",
                found ? (unsigned long)((const char *)ra - (const char *)info.dli_fbase) : 0UL, found && info.dli_sname ? info.dli_sname : "?");
    }
    realCxaThrow(exception, type, destructor);
}
static kern_return_t (*steamLookUp)(mach_port_t, const char *, mach_port_t *);
// Each image of the game's code as it loads, before its initializers: the answers above; libsteam_api also sees the
// game's pid. Its private steamclient set too: steamclient reads SteamAppId while it loads.
static void gameImageAdded(const struct mach_header *h, intptr_t slide) {
    Dl_info info; char real[PATH_MAX]; size_t n = strlen(gGame.code);
    if (gGame.state != 1 || !n || !dladdr(h, &info) || !info.dli_fname || !realpath(info.dli_fname, real)) return;
    const char *base = strrchr(real, '/') + 1;
    if (!strcmp(base, "steamclient_g.dylib") || !strcmp(base, "libtier0_g.dylib") || !strcmp(base, "libvstdlib_g.dylib") || !strcmp(base, "libaudig.dylib")) {
        rebind_symbols_image((void *)h, slide, (struct rebinding[]){{"getpid", gamePid, NULL}, {"ThreadGetCurrentProcessId", gamePid, NULL},
                                                                    {"getenv", gameGetenv, NULL}}, 3);
        return;
    }
    if (strncmp(real, gGame.code, n) || real[n] != '/') return;
    struct rebinding r[] = {{"dlopen", gameDlopen, (void **)&gameOrigDlopen}, {"getenv", gameGetenv, NULL},
                            {"bootstrap_look_up", steamLookUp, NULL}, {"SteamInternal_SteamAPI_Init", gameSteamInit, (void **)&realSteamInit},
                            {"__cxa_throw", gameCxaThrow, (void **)&realCxaThrow}, {"getpid", gamePid, NULL}};
    rebind_symbols_image((void *)h, slide, r, strcmp(strrchr(real, '/'), "/libsteam_api.dylib") ? 5 : 6);
}

// Runs the game whose executable is path (in app, a bundle in Steam's library) with argv and envp (taken, they live for
// the process). 0, or the errno Steam reports.
static int startSteamGame(NSString *app, NSString *path, char **argv, char **envp) {
    if (gGame.state) { say(@"a game already ran in this MacShack run; restart MacShack for another"); return EAGAIN; }
    say([NSString stringWithFormat:@"Steam starts %@: preparing it", app.lastPathComponent]);
    NSError *failure = nil;
    NSString *code = [ShackInstaller steamGameCodeRootForAppPath:app error:&failure];
    if (!code) { say([@"the game could not be prepared: " stringByAppendingString:failure.localizedDescription]); return ENOEXEC; }
    NSString *codeExe = [code stringByAppendingPathComponent:[path substringFromIndex:app.length]];
    gGame.app = app;
    gGame.argv = argv;
    for (gGame.argc = 0; argv[gGame.argc]; gGame.argc++) {}
    gGame.envp = envp;
    gGame.delegate = [[NSClassFromString(@"NSApplication") valueForKey:@"sharedApplication"] valueForKey:@"delegate"];
    if (!realpath(code.fileSystemRepresentation, gGame.code)) return ENOENT;
    NSDictionary *manifest = [ShackInstaller steamGameManifestForAppPath:app];
    gGame.translated = manifest[@"translate"] != nil;
    gGame.jitMB = ![manifest[@"requiresJIT"] boolValue] ? 0 : gGame.translated ? ShackTranslatedJITMB(app) : 128;
    if (!steamLookUp) {
        void *shim = dlopen("@rpath/libShackSteamClient.dylib", RTLD_LAZY | RTLD_NOLOAD);
        steamLookUp = (shim ? dlsym(shim, "bootstrap_look_up") : NULL) ?: dlsym(RTLD_DEFAULT, "bootstrap_look_up");
    }
    // GameMaker's Mac runner (data in game.ios) draws only with OpenGL.
    if ([NSFileManager.defaultManager fileExistsAtPath:[app stringByAppendingPathComponent:@"Contents/Resources/game.ios"]]) {
        setenv("SHACK_OPENGL", "1", 1);
        ShackHooksEnableGL();
    }
    if (gGame.translated) {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < gGame.argc; i++) [args addObject:@(argv[i])];
        args = [[@[@(argv[0])] arrayByAddingObjectsFromArray:ShackTranslatedArgs(app, args)] mutableCopy];
        gGame.argv = cStrings(args);   // also what NSProcessInfo shows the game (-force-metal)
        gGame.argc = (int)args.count;
        ShackHooksEnableGL();
    }
    ShackHooksAddGuest(app, path, code, gGame.translated, ^(int status) { gameEnded(status); });
    ShackHIDSetSecondGuestTest(ShackHooksIsSecondCaller);   // the game's pad callbacks apart from Steam's
    ShackHIDSetXbox2016(ShackWantsXbox2016(app));
    // The game's own frame cap and render scale (the same settings as on MacShack's Home; the island menu sets them).
    NSString *name = app.lastPathComponent.stringByDeletingPathExtension;
    ShackMetalSetFrameCap(ShackGameFrameCap(name, gGame.translated));
    ShackAppKitSetRenderScale(ShackGameRenderScale(name, gGame.translated));
    gGame.state = 1;
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64 << 20);
    int e = pthread_create(&gGame.thread, &at, gameThread, (void *)CFBridgingRetain(codeExe));
    if (e) { gGame.state = 0; say([NSString stringWithFormat:@"pthread_create: %d", e]); return e; }
    say([NSString stringWithFormat:@"%@ runs in-process as pid %d (%d arguments)", app.lastPathComponent, kGamePid, gGame.argc]);
    return 0;
}

static int steamPosixSpawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attr,
                           char *const argv[], char *const envp[]) {
    NSString *app = path ? steamGameApp(path) : nil;
    if (!app) {   // anything else goes to libShackSteamClient's refusal (SteamProcess.c), logged as before
        static int (*refuse)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
        void *shim = refuse ? NULL : dlopen("@rpath/libShackSteamClient.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (shim) refuse = dlsym(shim, "posix_spawn");
        return refuse ? refuse(pid, path, actions, attr, argv, envp) : EPERM;
    }
    int e = startSteamGame(app, @(path), copyStrings(argv, NULL), copyStrings(envp, NULL));
    if (!e && pid) *pid = kGamePid;
    return e;
}

// -[NSWorkspace launchApplicationAtURL:options:configuration:error:]: the app's executable from its Info.plist, the
// arguments and environment from the configuration; Steam reads the pid of the NSRunningApplication returned.
static Class gGameAppClass;   // the shim's NSRunningApplication as the game (made in ShackSteamClientInstall)
static id steamLaunchApplication(id self, SEL _cmd, NSURL *url, NSUInteger options, NSDictionary *config, NSError **error) {
    NSString *exe = [NSDictionary dictionaryWithContentsOfFile:[url.path stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleExecutable"];
    NSString *path = exe.length ? [url.path stringByAppendingFormat:@"/Contents/MacOS/%@", exe] : nil;
    NSString *app = path ? steamGameApp(path.fileSystemRepresentation) : nil;
    int e = ENOTSUP;
    if (app) {
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:path], *env = [NSMutableArray array];
        [args addObjectsFromArray:config[@"NSWorkspaceLaunchConfigurationArguments"] ?: @[]];
        NSDictionary<NSString *, NSString *> *vars = config[@"NSWorkspaceLaunchConfigurationEnvironment"];
        for (NSString *k in vars) [env addObject:[NSString stringWithFormat:@"%@=%@", k, vars[k]]];
        e = startSteamGame(app, path, cStrings(args), cStrings(env));
    } else say([@"Steam launches an app outside its library: refused: " stringByAppendingString:url.path]);
    if (e) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:e userInfo:nil]; return nil; }
    return [gGameAppClass new];
}

// Steam finds the focused window's process with CGWindowListCopyWindowInfo (the front window first, its owner pid) and
// sends a pad's input to Big Picture only while that is its web helper. The windows on screen, front first, each owned by
// the stand-in process that made it: Steam Helper's (made on the main thread) 1000001, the game's 1000002, else Steam.
NSArray *ShackAppKitFrontWindows(void);   // libShackAppKit, NSWindow objects
static BOOL isGameObject(id o) {   // its class comes from the game's code
    const char *image = o ? class_getImageName(object_getClass(o)) : NULL;
    char real[PATH_MAX]; size_t n = strlen(gGame.code);
    return image && n && realpath(image, real) && !strncmp(real, gGame.code, n) && real[n] == '/';
}
// SDL makes its windows on the main thread (Mina's SDLWindow), so the game's are also told by their own classes.
static int windowOwner(id w) {   // the AppKit shim's NSWindow: its own methods, typed
    pthread_t creator = ((pthread_t (*)(id, SEL))objc_msgSend)(w, sel_registerName("shack_creator"));
    if (gGame.state == 1 && (pthread_equal(creator, gGame.thread) || isGameObject(w) ||
                             isGameObject(((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("contentView"))))) return kGamePid;
    return ((BOOL (*)(id, SEL))objc_msgSend)(w, sel_registerName("shack_mainThreadWindow")) ? kHelperPid : getpid();
}
static CFArrayRef steamWindowList(uint32_t option, uint32_t relativeToWindow) {
    NSMutableArray *list = [NSMutableArray array];
    for (id w in ShackAppKitFrontWindows()) {
        int pid = windowOwner(w);
        BOOL game = pid == kGamePid, helper = pid == kHelperPid;
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(w, sel_registerName("frame"));
        NSInteger number = ((NSInteger (*)(id, SEL))objc_msgSend)(w, sel_registerName("windowNumber"));
        NSString *title = ((NSString *(*)(id, SEL))objc_msgSend)(w, sel_registerName("title"));
        NSDictionary *bounds = CFBridgingRelease(CGRectCreateDictionaryRepresentation(frame));
        [list addObject:@{@"kCGWindowNumber": @(number), @"kCGWindowOwnerPID": @(pid),
                          @"kCGWindowOwnerName": game ? @"Game" : helper ? @"Steam Helper" : @"steam_osx",
                          @"kCGWindowName": title ?: @"", @"kCGWindowLayer": @0, @"kCGWindowBounds": bounds,
                          @"kCGWindowIsOnscreen": @YES, @"kCGWindowAlpha": @1.0, @"kCGWindowSharingState": @1,
                          @"kCGWindowStoreType": @2, @"kCGWindowMemoryUsage": @0}];
    }
    return (CFArrayRef)CFBridgingRetain(list);
}

// Steam's UI also asks NSWorkspace for the frontmost application and gives Steam Input its pid as the focused window's
// owner: Big Picture's controller config (769) only while that is the owner of Big Picture's window, the web helper.
@interface ShackSteamFrontApp : NSObject
@property (nonatomic) pid_t processIdentifier;
@end
@implementation ShackSteamFrontApp
@end
static id steamFrontmostApplication(id self, SEL _cmd) {
    ShackSteamFrontApp *app = [ShackSteamFrontApp new];
    id front = ShackAppKitFrontWindows().firstObject;
    app.processIdentifier = front ? windowOwner(front) : getpid();
    static _Atomic pid_t last;   // diagnostic: Steam Input uses Big Picture's pad config only while this is the helper
    if (atomic_exchange(&last, app.processIdentifier) != app.processIdentifier)
        say([NSString stringWithFormat:@"front app for Steam Input: pid %d (%@)", app.processIdentifier, front ? [front valueForKey:@"title"] : @"no window"]);
    return app;
}

// Steam watches a game's pid with kevent(EVFILT_PROC). The stand-in pid becomes an EVFILT_USER event of the same ident on
// the same kqueue, triggered when the game ends and handed back to Steam as the NOTE_EXIT it asked for.
static int steamKevent(int kq, const struct kevent *changes, int nchanges, struct kevent *events, int nevents, const struct timespec *timeout) {
    struct kevent local[nchanges > 0 ? nchanges : 1];
    BOOL added = NO;
    for (int i = 0; i < nchanges; i++) {
        local[i] = changes[i];
        if (changes[i].filter != EVFILT_PROC || changes[i].ident != kGamePid) continue;
        local[i].filter = EVFILT_USER;
        local[i].fflags = 0;
        if (changes[i].flags & EV_ADD) { gGame.kq = kq; added = YES; }
        if ((changes[i].flags & EV_DELETE) && gGame.kq == kq) gGame.kq = -1;
    }
    if (added && gGame.state == 2) {   // it ended before Steam looked
        struct kevent ev;
        EV_SET(&ev, kGamePid, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
        origKevent(kq, &ev, 1, NULL, 0, NULL);
    }
    int n = origKevent(kq, nchanges ? local : changes, nchanges, events, nevents, timeout);
    for (int i = 0; i < n; i++) {
        if (events[i].filter != EVFILT_USER || events[i].ident != kGamePid) continue;
        events[i].filter = EVFILT_PROC;
        events[i].fflags = NOTE_EXIT | NOTE_EXITSTATUS;
        events[i].data = W_EXITCODE(gGame.status, 0);
    }
    return n;
}

void ShackSteamClientInstall(NSString *bundle, NSString *code) {
    gBundle = bundle; gCode = code;
    // The private images (the helper's, a game's Steam API) report Steam's originals: tier0 finds steamui and steam.cfg
    // beside its own image.
    NSMutableDictionary<NSString *, NSString *> *aliases = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, NSString *> *files in @[ShackSteamHelperFiles(), ShackSteamGameFiles()])
        for (NSString *original in files) aliases[files[original]] = original;
    ShackHooksSetImageAliases(aliases);
    struct rebinding r[] = {
        {"CreateSimpleProcess", steamCreateSimpleProcess, (void **)&origCreateSimpleProcess},
        {"kill", steamKill, (void **)&origKill},
        {"waitid", steamWaitid, (void **)&origWaitid},
        {"waitpid", steamWaitpid, (void **)&origWaitpid},
        {"_NSGetArgc", steamGetArgc, (void **)&origGetArgc},
        {"_NSGetArgv", steamGetArgv, (void **)&origGetArgv},
        {"posix_spawn", steamPosixSpawn, NULL},
        {"kevent", steamKevent, NULL},
        {"CGWindowListCopyWindowInfo", steamWindowList, NULL},
    };
    origKevent = dlsym(RTLD_DEFAULT, "kevent");   // libsystem's: fishhook fills an original only from images loaded now
    rebind_symbols(r, sizeof r / sizeof *r);   // every image, and those loaded later (Steam's own)
    Method front = class_getInstanceMethod(NSClassFromString(@"NSWorkspace"), sel_registerName("frontmostApplication"));
    if (front) method_setImplementation(front, (IMP)steamFrontmostApplication);
    // steamui reads frontmostApplication again only after NSWorkspace says the active app changed (its observers set a
    // flag, any thread will do): said here when the front window's owner changes (a game's window comes up, the game
    // quits), so Steam Input moves the pad between Big Picture and the game.
    // While a game's window has the screen, Steam's display links sleep (`steamSleep`, default on): Chromium then draws
    // nothing behind the game. Its threads keep running, so the game's Steam API calls are answered as before.
    // ponytail: polled twice a second; a hook where the shim orders windows if the half-second lag ever matters.
    static dispatch_source_t focus;
    static pid_t announced;
    focus = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(focus, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(focus, ^{
        id window = ShackAppKitFrontWindows().firstObject;
        pid_t owner = window ? windowOwner(window) : getpid();
        if (owner == announced) return;
        announced = owner;
        id sleep = [NSUserDefaults.standardUserDefaults objectForKey:@"steamSleep"];
        BOOL asleep = owner == kGamePid && (!sleep || [sleep boolValue]);
        ShackCVSleepLinksOf(asleep ? "/Guests/SteamClient/" : NULL);
        say(asleep ? @"a game has the screen: Steam's display links sleep" : @"Steam's display links awake");
        [NSNotificationCenter.defaultCenter postNotificationName:@"NSWorkspaceDidActivateApplicationNotification" object:nil];
    });
    dispatch_resume(focus);
    // A game's code: its own environment, Steam API and ipcserver (gameImageAdded); after ShackHooks' own rebinding of
    // each new image, whose dlopen it keeps as the original. Called back for the images loaded now too (none a game's).
    realGetenv = dlsym(RTLD_DEFAULT, "getenv");
    _dyld_register_func_for_add_image(gameImageAdded);
    // Games Steam starts as app bundles, and the NSRunningApplication it gets back: the game's pid, bundle and end.
    // Added here, not in libShackSteamClient, which loads with steam_osx: after this, and a category there would win.
    Class running = NSClassFromString(@"NSRunningApplication"), workspace = NSClassFromString(@"NSWorkspace");
    if (running && workspace && (gGameAppClass = objc_allocateClassPair(running, "ShackSteamGameApp", 0))) {
        class_addMethod(gGameAppClass, sel_registerName("processIdentifier"), imp_implementationWithBlock(^pid_t(id s) { return kGamePid; }), "i@:");
        class_addMethod(gGameAppClass, sel_registerName("isTerminated"), imp_implementationWithBlock(^BOOL(id s) { return gGame.state == 2; }), "B@:");
        class_addMethod(gGameAppClass, sel_registerName("bundleURL"), imp_implementationWithBlock(^NSURL *(id s) { return [NSURL fileURLWithPath:gGame.app]; }), "@@:");
        class_addMethod(gGameAppClass, sel_registerName("bundleIdentifier"), imp_implementationWithBlock(^NSString *(id s) {
            return [NSDictionary dictionaryWithContentsOfFile:[gGame.app stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleIdentifier"];
        }), "@@:");
        class_addMethod(gGameAppClass, sel_registerName("terminate"), imp_implementationWithBlock(^BOOL(id s) {
            say(@"Steam asked the game to quit: ignored, a game in this process quits from its own menu"); return NO;
        }), "B@:");
        class_addMethod(gGameAppClass, sel_registerName("forceTerminate"), class_getMethodImplementation(gGameAppClass, sel_registerName("terminate")), "B@:");
        objc_registerClassPair(gGameAppClass);
        class_replaceMethod(workspace, sel_registerName("launchApplicationAtURL:options:configuration:error:"), (IMP)steamLaunchApplication, "@@:@Q@^@");
    }
}
