// One-process Steam on the Mac (prototype, see README.md): steam_osx, Steam Helper's browser process (CEF, in
// --single-process mode) and a game Steam launches all run in one process, as "guests" taking turns on the main thread.
// Interposers must live in a dylib (dyld only honors __interpose there), so all of this is libonehost.dylib and
// shacksteam is a three-line main.
#import <AppKit/AppKit.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <arpa/inet.h>
#import <servers/bootstrap.h>
#import <libproc.h>
#import <sys/proc_info.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <spawn.h>
#import <stdarg.h>
#import <sys/event.h>
#import <sys/mman.h>
#import <sys/wait.h>
#import <unistd.h>

// Steam launches games with NSWorkspace's pre-macOS 11 configuration keys, so this does too.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef int (*guest_main_t)(int, char **, char **, char **);
// tier0's process API (libtier0_s.dylib): a process handle is its pid. Flags decoded from its disassembly:
// 0x2 setsid, 0x8 execv(argv), 0x10 execvp(argv), 0x4 "exec <cmd>" through sh, otherwise system(cmd); 0x20 unsupported.
pid_t CreateSimpleProcess(void *argvOrCommand, uint32_t flags, char **envp, const char *cwd);
void *dlopen_from(const char *path, int mode, void *addressInCaller);   // dyld: dlopen as if called from that image

static void say(const char *fmt, ...) {
    static FILE *f;
    if (!f) {
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/Library/Application Support/Steam/logs/onehost.log", getenv("HOME"));
        f = fopen(path, "a");
    }
    va_list ap;
    char line[4096];
    va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    fprintf(stderr, "[onehost] %s\n", line);
    if (f) { fprintf(f, "%s [onehost] %s\n", [[NSDate date].description UTF8String], line); fflush(f); }
}

static void sayArgv(const char *what, const char *path, char *const argv[]) {
    char buf[3000] = "";
    for (int i = 0; argv && argv[i] && strlen(buf) < sizeof buf - 200; i++) {
        strlcat(buf, i ? " '" : "'", sizeof buf); strlcat(buf, argv[i], sizeof buf); strlcat(buf, "'", sizeof buf);
    }
    say("%s %s :: %s", what, path, buf);
}

static char **copyStrings(char *const *v, char *const *extra) {
    int n = 0, e = 0;
    while (v && v[n]) n++;
    while (extra && extra[e]) e++;
    char **out = calloc(n + e + 1, sizeof *out);
    for (int i = 0; i < n; i++) out[i] = strdup(v[i]);
    for (int i = 0; i < e; i++) out[n + i] = strdup(extra[i]);
    return out;
}

static char steamDir[PATH_MAX];   // .../Steam.AppBundle/Steam/Contents/MacOS
static char guestsDir[PATH_MAX];  // .../Application Support/Steam/onehost-guests: games build.sh prepared
static char **hostApple;

static guest_main_t loadMain(const char *path) {
    if (!dlopen(path, RTLD_NOW | RTLD_GLOBAL)) { say("dlopen %s: %s", path, dlerror()); return NULL; }
    char want[PATH_MAX], have[PATH_MAX];
    if (!realpath(path, want)) return NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (!realpath(_dyld_get_image_name(i), have) || strcmp(have, want)) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const struct load_command *lc = (const void *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize))
            if (lc->cmd == LC_MAIN) return (guest_main_t)((const char *)h + ((const struct entry_point_command *)lc)->entryoff);
    }
    say("%s: loaded but no LC_MAIN", path);
    return NULL;
}

// --- guests: in-process stand-ins for the processes steam_osx starts ---

// AppKit, SDL and CEF all insist on the real main thread, for steam_osx as much as for its helper and the game, so all
// of them run there, taking turns like cooperative threads (fibers). steam_osx keeps the thread's own stack; each guest
// gets one of its own. Turns change where a program would wait: it asks for the next event, or sleeps on the main
// thread. Never inside a run loop callout: run loop invocations on one thread must unwind in order. Each fiber keeps its
// own autorelease pool stack (objc's TLS slot is swapped on every switch).
// Guest pids are fake: macOS pids stay below 100000, so they never name a real process even if a call slips past.
enum { kPoolSlot = 43 };   // objc4: AUTORELEASE_POOL_KEY = __PTK_FRAMEWORK_OBJC_KEY3 (40 + 3)
enum { kNone, kPending, kRunning, kDone };
typedef struct { void *sp, *pool; } fiber_t;
typedef struct {
    char name[256];
    pid_t pid;
    int state, argc, status;
    char **argv, **env;
    char exe[PATH_MAX];    // the original executable: what the guest's own images see as theirs
    char image[PATH_MAX];  // the converted executable that is loaded
    char dir[PATH_MAX];    // games: images under this directory are the game's (the helper's are matched by name)
    char bundle[PATH_MAX]; // games: their main bundle
    fiber_t fiber;
    int kq;                // the kqueue that watches the guest's exit (Steam's kevent EVFILT_PROC), or -1
} guest_t;
static guest_t helper = { "Steam Helper", 1000001, .kq = -1 }, game = { "game", 1000002, .kq = -1 };
static guest_t *const guests[] = { &helper, &game };
enum { kGuests = sizeof guests / sizeof *guests };
static fiber_t mainFiber, *current = &mainFiber;
static guest_t *currentGuest;   // NULL while steam_osx has the main thread

static int runnable(const guest_t *g) { return g->state == kPending || g->state == kRunning; }
static guest_t *guestForPid(uintptr_t pid) {
    for (int i = 0; i < kGuests; i++) if ((uintptr_t)guests[i]->pid == pid && guests[i]->state != kNone) return guests[i];
    return NULL;
}

void onehost_fiber_swap(void **saveSp, void *loadSp);
__asm__(".text\n.p2align 2\n.private_extern _onehost_fiber_swap\n_onehost_fiber_swap:\n"
        "sub sp, sp, #160\n"
        "stp x19, x20, [sp, #0]\n stp x21, x22, [sp, #16]\n stp x23, x24, [sp, #32]\n stp x25, x26, [sp, #48]\n"
        "stp x27, x28, [sp, #64]\n stp x29, x30, [sp, #80]\n stp d8, d9, [sp, #96]\n stp d10, d11, [sp, #112]\n"
        "stp d12, d13, [sp, #128]\n stp d14, d15, [sp, #144]\n"
        "mov x9, sp\n str x9, [x0]\n mov sp, x1\n"
        "ldp x19, x20, [sp, #0]\n ldp x21, x22, [sp, #16]\n ldp x23, x24, [sp, #32]\n ldp x25, x26, [sp, #48]\n"
        "ldp x27, x28, [sp, #64]\n ldp x29, x30, [sp, #80]\n ldp d8, d9, [sp, #96]\n ldp d10, d11, [sp, #112]\n"
        "ldp d12, d13, [sp, #128]\n ldp d14, d15, [sp, #144]\n"
        "add sp, sp, #160\n ret\n");

static void **tsd(void) { uintptr_t p; __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(p)); return (void **)(p & ~(uintptr_t)7); }
static void switchTo(guest_t *to) {   // NULL = steam_osx
    fiber_t *from = current, *next = to ? &to->fiber : &mainFiber;
    from->pool = tsd()[kPoolSlot]; tsd()[kPoolSlot] = next->pool;
    current = next; currentGuest = to;
    onehost_fiber_swap(&from->sp, next->sp);
}

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);
static void *poolSlotProbe(void *ok) {   // a fresh thread has no pool page until its first push
    void *before = tsd()[kPoolSlot], *token = objc_autoreleasePoolPush(), *after = tsd()[kPoolSlot];
    objc_autoreleasePoolPop(token);
    *(int *)ok = !before && after;
    return NULL;
}
static int poolSlotIsRight(void) {
    int ok = 0;
    pthread_t t;
    pthread_create(&t, NULL, poolSlotProbe, &ok);
    pthread_join(t, NULL);
    return ok;
}

// The guest's end: whoever watches its pid (Steam's kevent) hears NOTE_EXIT.
static void guestEnded(guest_t *g, int status) {
    g->status = status;
    g->state = kDone;
    say("%s (pid %d) ended with %d", g->name, g->pid, status);
    if (g->kq >= 0) kevent(g->kq, &(struct kevent){ .ident = (uintptr_t)g->pid, .filter = EVFILT_USER, .fflags = NOTE_TRIGGER }, 1, NULL, 0, NULL);
}

static void guestFiberMain(void) {
    guest_t *g = currentGuest;
    guest_main_t main = loadMain(g->image);
    if (main) {
        sayArgv("calling main on its fiber:", g->name, g->argv);
        guestEnded(g, main(g->argc, g->argv, g->env, hostApple));
    } else guestEnded(g, 127);
    switchTo(NULL);
    abort();   // a finished fiber is never resumed
}

static void startFiber(guest_t *g) {
    size_t size = 64 << 20;   // Chromium's main thread expects a big stack
    char *stack = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mprotect(stack, 16384, PROT_NONE);   // guard page
    uint64_t *frame = (uint64_t *)(stack + size) - 20;   // the 160-byte frame onehost_fiber_swap pops
    memset(frame, 0, 160);
    frame[11] = (uint64_t)guestFiberMain;   // x30: where its ret lands; x29 = 0 ends backtraces there
    g->fiber = (fiber_t){ frame, NULL };
    g->state = kRunning;
}

static int insideRunLoop(void) {
    CFRunLoopMode mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    if (mode) CFRelease(mode);
    return mode != NULL;
}

// A switch point: the next runnable program gets the main thread, round robin (steam_osx, helper, game, steam_osx...).
static void yieldMainThread(void) {
    if (!pthread_main_np() || insideRunLoop()) return;
    int at = 0;   // slot 0 is steam_osx, slot i + 1 is guests[i]
    for (int i = 0; i < kGuests; i++) if (guests[i] == currentGuest) at = i + 1;
    for (int step = 1; step <= kGuests; step++) {
        int slot = (at + step) % (kGuests + 1);
        guest_t *g = slot ? guests[slot - 1] : NULL;
        if (g && !runnable(g)) continue;
        if (g && g->state == kPending) startFiber(g);
        switchTo(g);
        return;
    }
}

// Sleeping on the main thread while a game runs: the others take turns until the deadline, in slices short enough for
// the game's frames. ponytail: a 1 ms slice poll, not a scheduler; sleep until the earliest wake-up across fibers if the
// CPU cost shows.
static void sleepMainThread(uint64_t ns) {
    yieldMainThread();
    if (game.state != kRunning || insideRunLoop()) { nanosleep(&(struct timespec){ (time_t)(ns / 1000000000), (long)(ns % 1000000000) }, NULL); return; }
    uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + ns;
    for (uint64_t now; (now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) < end; yieldMainThread())
        nanosleep(&(struct timespec){ 0, (long)MIN(end - now, 1000000) }, NULL);
}

// --- the Steam Helper browser ---

static int isHelperBrowser(char *const argv[]) {
    if (!argv || !argv[0]) return 0;
    const char *base = strrchr(argv[0], '/');
    if (strcmp(base ? base + 1 : argv[0], "Steam Helper")) return 0;
    for (int i = 1; argv[i]; i++) if (!strncmp(argv[i], "--type=", 7)) return 0;
    return 1;
}

// Called on whatever thread steam_osx launches from; the fiber starts at the main thread's next switch point.
static pid_t startHelper(char *const argv[], char *const envp[], const char *cwd) {
    if (runnable(&helper)) { say("Steam Helper already runs in-process; refusing a second one"); return 0; }
    if (helper.state == kDone) { say("Steam Helper ran once already; a second run needs a fresh image (not yet)"); return 0; }
    char path[PATH_MAX], fw[PATH_MAX], bundle[PATH_MAX], fwArg[PATH_MAX + 32], bundleArg[PATH_MAX + 32];
    snprintf(path, sizeof path, "%s/../Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper", steamDir);
    if (!realpath(path, helper.exe)) strlcpy(helper.exe, path, sizeof helper.exe);
    snprintf(helper.image, sizeof helper.image, "%s/Steam Helper.onehost.dylib", steamDir);
    // CEF finds its framework and bundle from the main bundle, which is Steam's here, not Steam Helper.app: say so.
    snprintf(path, sizeof path, "%s/../Frameworks/Chromium Embedded Framework.framework", steamDir);
    if (!realpath(path, fw)) strlcpy(fw, path, sizeof fw);
    snprintf(path, sizeof path, "%s/../Frameworks/Steam Helper.app", steamDir);
    if (!realpath(path, bundle)) strlcpy(bundle, path, sizeof bundle);
    snprintf(fwArg, sizeof fwArg, "--framework-dir-path=%s", fw);
    snprintf(bundleArg, sizeof bundleArg, "--main-bundle-path=%s", bundle);
    // ponytail: one extra argument (ONEHOST_HELPER_ARG=--js-flags=--jitless, say); a list when an experiment needs two.
    char *extra[] = { "--single-process", fwArg, bundleArg, getenv("ONEHOST_HELPER_ARG"), NULL };
    helper.argv = copyStrings(argv, extra);
    helper.env = copyStrings(envp ? envp : *_NSGetEnviron(), NULL);
    for (helper.argc = 0; helper.argv[helper.argc]; helper.argc++) {}
    sayArgv("Steam Helper in-process (cwd ignored)", cwd ? cwd : "", helper.argv);
    helper.state = kPending;
    return helper.pid;
}

// --- games ---

// Steam's handle on a game it launched: a pid, read from this. The in-process game gets a stand-in.
@interface OneHostRunningGame : NSRunningApplication
@end
@implementation OneHostRunningGame
- (pid_t)processIdentifier { return game.pid; }
- (NSURL *)bundleURL { return [NSURL fileURLWithPath:@(game.bundle)]; }
- (NSURL *)executableURL { return [NSURL fileURLWithPath:@(game.exe)]; }
- (NSString *)bundleIdentifier { return [NSBundle bundleWithPath:@(game.bundle)].bundleIdentifier; }
- (NSString *)localizedName { return @(game.name); }
- (BOOL)isFinishedLaunching { return YES; }
- (BOOL)isTerminated { return game.state == kDone; }
- (BOOL)terminate { say("Steam asked %s to quit: not supported in-process yet", game.name); return NO; }
- (BOOL)forceTerminate { return [self terminate]; }
@end

// A game build.sh prepared (onehost-guests/<Game>.app/<executable>.dylib) runs in-process; any other launches normally.
static NSRunningApplication *startGame(NSURL *url, NSDictionary *config) {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    NSString *dir = [@(guestsDir) stringByAppendingPathComponent:url.lastPathComponent];
    NSString *image = [dir stringByAppendingPathComponent:[bundle.executablePath.lastPathComponent stringByAppendingString:@".dylib"]];
    if (!bundle.executablePath || ![NSFileManager.defaultManager fileExistsAtPath:image]) return nil;
    if (runnable(&game)) { say("%s already runs in-process; one game at a time", game.name); return nil; }
    if (game.state == kDone) { say("a game ran in this process already; images cannot be unloaded, so another needs a restart"); return nil; }
    strlcpy(game.name, url.lastPathComponent.stringByDeletingPathExtension.UTF8String, sizeof game.name);
    strlcpy(game.exe, bundle.executablePath.UTF8String, sizeof game.exe);
    strlcpy(game.image, image.UTF8String, sizeof game.image);
    strlcpy(game.dir, dir.UTF8String, sizeof game.dir);
    strlcpy(game.bundle, url.path.UTF8String, sizeof game.bundle);
    NSArray<NSString *> *args = config[NSWorkspaceLaunchConfigurationArguments];
    game.argc = 1 + (int)args.count;
    game.argv = calloc(game.argc + 1, sizeof *game.argv);
    game.argv[0] = strdup(game.exe);
    for (NSUInteger i = 0; i < args.count; i++) game.argv[i + 1] = strdup(args[i].UTF8String);
    NSDictionary<NSString *, NSString *> *env = config[NSWorkspaceLaunchConfigurationEnvironment];
    game.env = calloc(env.count + 1, sizeof *game.env);
    int n = 0;
    for (NSString *k in env) game.env[n++] = strdup([NSString stringWithFormat:@"%@=%@", k, env[k]].UTF8String);
    game.state = kPending;
    say("%s in-process as pid %d (%lu arguments, %d environment variables)", game.name, game.pid, (unsigned long)args.count, n);
    return [OneHostRunningGame new];
}

// Which guest an image belongs to, by the image a caller's return address lies in (NULL: steam_osx's own).
static guest_t *owner(const void *ra) {
    if (helper.state == kNone && game.state == kNone) return NULL;
    Dl_info info;
    if (!dladdr(ra, &info) || !info.dli_fname) return NULL;
    if (game.state != kNone && !strncmp(info.dli_fname, game.dir, strlen(game.dir))) return &game;
    if (helper.state == kNone) return NULL;
    const char *f = strrchr(info.dli_fname, '/');
    f = f ? f + 1 : info.dli_fname;
    return !strcmp(f, "Steam Helper.onehost.dylib") || !strcmp(f, "Chromium Embedded Framework") ||
           !strcmp(f, "libtier0_h.dylib") || !strcmp(f, "libvstdlib_h.dylib") || !strcmp(f, "libSDLh.dylib") ? &helper : NULL;
}

// --- interposers ---

// ONEHOST_NO_SPAWN=1: the iOS sandbox's answer to starting any real program (fork, exec, posix_spawn, a launch of an
// unprepared app), to find what Steam needs from the helpers it starts before trying the phone.
static int refuseSpawn(const char *what, const char *path) {
    static int noSpawn = -1;
    if (noSpawn < 0) noSpawn = getenv("ONEHOST_NO_SPAWN") != NULL;
    if (noSpawn) say("refused (iOS spawn policy): %s %s", what, path ? path : "");
    return noSpawn;
}

static pid_t onehost_CreateSimpleProcess(void *argvOrCommand, uint32_t flags, char **envp, const char *cwd) {
    if ((flags & 0x18) && isHelperBrowser(argvOrCommand)) return startHelper(argvOrCommand, envp, cwd);
    if (refuseSpawn("CreateSimpleProcess", flags & 0x18 ? ((char **)argvOrCommand)[0] : argvOrCommand)) return 0;
    pid_t pid = CreateSimpleProcess(argvOrCommand, flags, envp, cwd);
    if (flags & 0x18) sayArgv("CreateSimpleProcess", "", argvOrCommand);
    else say("CreateSimpleProcess (shell) %s", (const char *)argvOrCommand);
    say("  -> pid %d", pid);
    return pid;
}

// Guest pids for steam_osx: alive while running, an exit status after.
static int onehost_kill(pid_t pid, int sig) {
    guest_t *g = guestForPid(pid);
    if (!g) return kill(pid, sig);
    if (sig) say("kill(%s, %d): ignored", g->name, sig);
    if (!runnable(g)) { errno = ESRCH; return -1; }
    return 0;
}
static int onehost_waitid(idtype_t type, id_t id, siginfo_t *info, int options) {
    guest_t *g = type == P_PID ? guestForPid(id) : NULL;
    if (!g) return waitid(type, id, info, options);
    if (runnable(g) && !(options & WNOHANG)) say("waitid(%s) without WNOHANG: blocking until it ends", g->name);
    while (runnable(g) && !(options & WNOHANG)) sleep(1);
    if (info) memset(info, 0, sizeof *info);   // si_pid 0 = still running
    if (!runnable(g) && info) { info->si_pid = g->pid; info->si_code = CLD_EXITED; info->si_status = g->status; }
    return 0;
}
static pid_t onehost_waitpid(pid_t pid, int *status, int options) {
    guest_t *g = guestForPid(pid);
    if (!g) return waitpid(pid, status, options);
    if (runnable(g)) return 0;
    if (status) *status = W_EXITCODE(g->status, 0);
    return pid;
}

// Steam watches a game's pid with kevent(EVFILT_PROC). A guest pid becomes an EVFILT_USER event of the same ident on the
// same kqueue, triggered when the guest ends and handed back to Steam as the NOTE_EXIT it asked for.
static int onehost_kevent(int kq, const struct kevent *changes, int nchanges, struct kevent *events, int nevents, const struct timespec *timeout) {
    struct kevent local[nchanges + 1];
    guest_t *added = NULL;
    for (int i = 0; i < nchanges; i++) {
        local[i] = changes[i];
        guest_t *g = changes[i].filter == EVFILT_PROC ? guestForPid(changes[i].ident) : NULL;
        if (!g) continue;
        say("kevent: Steam %s %s (pid %d), fflags 0x%x", changes[i].flags & EV_DELETE ? "stops watching" : "watches", g->name, g->pid, changes[i].fflags);
        local[i].filter = EVFILT_USER;
        local[i].fflags = 0;
        if (changes[i].flags & EV_ADD) { g->kq = kq; added = g; }
        if ((changes[i].flags & EV_DELETE) && g->kq == kq) g->kq = -1;
    }
    int n = kevent(kq, local, nchanges, events, nevents, timeout);
    if (added && added->state == kDone) guestEnded(added, added->status);   // it ended before Steam looked
    for (int i = 0; i < n; i++) {
        guest_t *g = events[i].filter == EVFILT_USER ? guestForPid(events[i].ident) : NULL;
        if (!g || g->kq != kq) continue;
        events[i].filter = EVFILT_PROC;
        events[i].fflags = NOTE_EXIT | NOTE_EXITSTATUS;
        events[i].data = W_EXITCODE(g->status, 0);
    }
    return n;
}

static int onehost_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    sayArgv("posix_spawn", path, argv);
    if (refuseSpawn("posix_spawn", path)) return EPERM;
    int rc = posix_spawn(pid, path, fa, attr, argv, envp);
    say("  -> rc %d pid %d", rc, pid ? *pid : -1);
    return rc;
}
// ipcserver: Steam's launchd agent (MachServices com.valvesoftware.steam.ipctool) through which a game's libsteam_api
// finds the running Steam. iOS has neither launchd agents nor global Mach services, but every client is in this process,
// so the service is emulated here: one port, its receive right handed to ipcserver at check-in (ipcserver runs on a
// thread of its own: Foundation only, no AppKit), a send right to whoever looks it up.
static const char kIpcService[] = "com.valvesoftware.steam.ipctool";
static mach_port_t ipcPort;
static void *ipcServerThread(void *unused) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/ipcserver.onehost.dylib", steamDir);
    guest_main_t main = loadMain(path);
    char *argv[] = { path, NULL };
    if (main) say("ipcserver main returned %d", main(1, argv, *_NSGetEnviron(), hostApple));
    return NULL;
}
static mach_port_t ipcServicePort(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ipcPort);
        mach_port_insert_right(mach_task_self(), ipcPort, ipcPort, MACH_MSG_TYPE_MAKE_SEND);
        pthread_t t;
        pthread_create(&t, NULL, ipcServerThread, NULL);
        pthread_detach(t);
        say("ipcserver in-process (service port 0x%x)", ipcPort);
    });
    return ipcPort;
}
static kern_return_t onehost_bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *port) {
    if (strcmp(name, kIpcService)) return bootstrap_check_in(bp, name, port);
    *port = ipcServicePort();
    return KERN_SUCCESS;
}
static kern_return_t onehost_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *port) {
    if (strcmp(name, kIpcService)) return bootstrap_look_up(bp, name, port);
    *port = ipcServicePort();
    mach_port_mod_refs(mach_task_self(), *port, MACH_PORT_RIGHT_SEND, 1);   // the caller's own send right to release
    return KERN_SUCCESS;
}

// Steam (steamclient, steamui) asks lsof which process holds a local TCP connection before trusting it (popen of
// "/usr/sbin/lsof -F up -i TCP@127.0.0.1:<port>"). iOS has no lsof and no exec, so the answer comes from here, in lsof's
// -F up format: this process, if one of its own TCP sockets uses that port (so another app on the device is not
// vouched for), else nothing.
static int ownSocketUsesPort(int port) {
    int size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) return 0;
    struct proc_fdinfo *fds = malloc((size_t)size);
    int n = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, size) / (int)sizeof *fds, found = 0;
    for (int i = 0; i < n && !found; i++) {
        struct socket_fdinfo si;
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET ||
            proc_pidfdinfo(getpid(), fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof si) != sizeof si ||
            si.psi.soi_kind != SOCKINFO_TCP) continue;
        struct in_sockinfo *in = &si.psi.soi_proto.pri_tcp.tcpsi_ini;
        found = ntohs((uint16_t)in->insi_lport) == port || ntohs((uint16_t)in->insi_fport) == port;
    }
    free(fds);
    return found;
}
static FILE *lsofAnswers[16];   // ponytail: a fixed table; Steam closes each answer right after reading it
static FILE *onehost_popen(const char *command, const char *mode) {
    int port;
    if (command && sscanf(command, "/usr/sbin/lsof -F up -i TCP@127.0.0.1:%d", &port) == 1) {
        static char answer[64];
        int len = ownSocketUsesPort(port) ? snprintf(answer, sizeof answer, "p%d\nu%d\n", getpid(), getuid()) : 0;
        FILE *f = fmemopen(len ? strdup(answer) : strdup(" "), len ? (size_t)len : 1, "r");
        if (!len) fgetc(f);   // an empty answer: lsof found nothing
        for (int i = 0; i < 16; i++) if (!lsofAnswers[i]) { lsofAnswers[i] = f; break; }
        return f;
    }
    if (refuseSpawn("popen", command)) { errno = EPERM; return NULL; }
    return popen(command, mode);
}
static int onehost_pclose(FILE *f) {
    for (int i = 0; i < 16; i++) if (f && lsofAnswers[i] == f) { lsofAnswers[i] = NULL; fclose(f); return 0; }
    return pclose(f);
}
static int onehost_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return refuseSpawn("posix_spawnp", file) ? EPERM : posix_spawnp(pid, file, fa, attr, argv, envp);
}
static int onehost_execv(const char *path, char *const argv[]) {
    sayArgv("execv", path, argv);
    for (char **e = *_NSGetEnviron(); *e; e++) if (!strncmp(*e, "STEAM", 5)) say("  with %s", *e);
    if (refuseSpawn("execv", path)) { errno = EPERM; return -1; }
    return execv(path, argv);
}
static int onehost_execve(const char *path, char *const argv[], char *const envp[]) {
    if (refuseSpawn("execve", path)) { errno = EPERM; return -1; }
    return execve(path, argv, envp);
}
static int onehost_execvp(const char *file, char *const argv[]) {
    if (refuseSpawn("execvp", file)) { errno = EPERM; return -1; }
    return execvp(file, argv);
}
static pid_t onehost_fork(void) {
    if (refuseSpawn("fork", "")) { errno = EPERM; return -1; }
    return fork();
}

// A guest's own view of its process: executable path, argv, environment, pid, main bundle. CEF finds its framework
// relative to its executable; games read SteamAppId and friends from their environment.
static int onehost_NSGetExecutablePath(char *buf, uint32_t *size) {
    guest_t *g = owner(__builtin_return_address(0));
    if (!g) return _NSGetExecutablePath(buf, size);
    uint32_t need = (uint32_t)strlen(g->exe) + 1;
    if (*size < need) { *size = need; return -1; }
    memcpy(buf, g->exe, need);
    return 0;
}
static int onehost_proc_pidpath(int pid, void *buf, uint32_t size) {
    guest_t *g = guestForPid(pid);
    if (!g && pid == getpid()) g = owner(__builtin_return_address(0));
    if (!g) return proc_pidpath(pid, buf, size);
    if (strlen(g->exe) >= size) { errno = ENOMEM; return 0; }
    return (int)strlcpy(buf, g->exe, size);
}
static int *onehost_NSGetArgc(void) {
    guest_t *g = owner(__builtin_return_address(0));
    return g && g->argv ? &g->argc : _NSGetArgc();
}
static char ***onehost_NSGetArgv(void) {
    guest_t *g = owner(__builtin_return_address(0));
    return g && g->argv ? &g->argv : _NSGetArgv();
}
static char *onehost_getenv(const char *name) {
    if (game.state == kNone || owner(__builtin_return_address(0)) != &game) return getenv(name);
    size_t n = strlen(name);
    for (char **e = game.env; *e; e++) if (!strncmp(*e, name, n) && (*e)[n] == '=') return *e + n + 1;
    return NULL;
}
static pid_t onehost_getpid(void) {
    return game.state != kNone && owner(__builtin_return_address(0)) == &game ? game.pid : getpid();
}
static CFBundleRef onehost_CFBundleGetMainBundle(void) {
    if (game.state == kNone || owner(__builtin_return_address(0)) != &game) return CFBundleGetMainBundle();
    static CFBundleRef bundle;
    if (!bundle) bundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@(game.bundle)]);
    return bundle;
}
// The game ending: exit on its own fiber parks the fiber; on another of its threads, parks that thread.
static void gameExit(int status) {
    guestEnded(&game, status);
    if (current == &game.fiber) switchTo(NULL);
    for (;;) pause();
}
static void onehost_exit(int status) { if (owner(__builtin_return_address(0)) == &game) gameExit(status); exit(status); }
static void onehost__exit(int status) { if (owner(__builtin_return_address(0)) == &game) gameExit(status); _exit(status); }
// The game loads its own steamclient.dylib, as its own process would: a private copy (build.sh game), not Steam's.
static void *onehost_dlopen(const char *path, int mode) {
    void *ra = __builtin_return_address(0);
    if (path && owner(ra) == &game) {
        const char *base = strrchr(path, '/');
        if (!strcmp(base ? base + 1 : path, "steamclient.dylib")) {
            char mine[PATH_MAX];
            snprintf(mine, sizeof mine, "%s/steamclient_g.dylib", game.dir);
            say("%s: dlopen %s -> %s", game.name, path, mine);
            return dlopen_from(mine, mode, ra);
        }
        say("%s: dlopen %s", game.name, path);
    }
    return dlopen_from(path, mode, ra);
}

static int onehost_nanosleep(const struct timespec *req, struct timespec *rem) {
    if (!pthread_main_np()) return nanosleep(req, rem);
    sleepMainThread((uint64_t)req->tv_sec * 1000000000 + (uint64_t)req->tv_nsec);
    return 0;
}
static int onehost_usleep(useconds_t us) {
    if (!pthread_main_np()) return usleep(us);
    sleepMainThread((uint64_t)us * 1000);
    return 0;
}

#define INTERPOSE(mine, theirs) \
    __attribute__((used)) static struct { const void *a, *b; } interpose_##theirs \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&mine, (const void *)&theirs };
INTERPOSE(onehost_CreateSimpleProcess, CreateSimpleProcess)
INTERPOSE(onehost_kill, kill)
INTERPOSE(onehost_waitid, waitid)
INTERPOSE(onehost_waitpid, waitpid)
INTERPOSE(onehost_kevent, kevent)
INTERPOSE(onehost_posix_spawn, posix_spawn)
INTERPOSE(onehost_execv, execv)
INTERPOSE(onehost_posix_spawnp, posix_spawnp)
INTERPOSE(onehost_execve, execve)
INTERPOSE(onehost_execvp, execvp)
INTERPOSE(onehost_fork, fork)
INTERPOSE(onehost_popen, popen)
INTERPOSE(onehost_pclose, pclose)
INTERPOSE(onehost_bootstrap_check_in, bootstrap_check_in)
INTERPOSE(onehost_bootstrap_look_up, bootstrap_look_up)
INTERPOSE(onehost_nanosleep, nanosleep)
INTERPOSE(onehost_usleep, usleep)
INTERPOSE(onehost_NSGetExecutablePath, _NSGetExecutablePath)
INTERPOSE(onehost_proc_pidpath, proc_pidpath)
INTERPOSE(onehost_NSGetArgc, _NSGetArgc)
INTERPOSE(onehost_NSGetArgv, _NSGetArgv)
INTERPOSE(onehost_getenv, getenv)
INTERPOSE(onehost_getpid, getpid)
INTERPOSE(onehost_CFBundleGetMainBundle, CFBundleGetMainBundle)
INTERPOSE(onehost_exit, exit)
INTERPOSE(onehost__exit, _exit)
INTERPOSE(onehost_dlopen, dlopen)

// The turn-taking at event pumps: a guest's event loop ([NSApp run], SDL) runs one non-blocking pass and passes the turn
// on (a bare yield starved CEF's main-thread tasks while steam_osx slept); steam_osx's pump passes the turn first, and
// while a game runs it must not park the thread until its next frame. Inside a run loop callout it is a plain pump.
static void shareMainThread(void) {
    SEL sel = @selector(nextEventMatchingMask:untilDate:inMode:dequeue:);
    Method m = class_getInstanceMethod([NSApplication class], sel);
    typedef NSEvent *(*pump_t)(id, SEL, NSEventMask, NSDate *, NSRunLoopMode, BOOL);
    pump_t orig = (pump_t)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^NSEvent *(id app, NSEventMask mask, NSDate *until, NSRunLoopMode mode, BOOL dequeue) {
        if (!pthread_main_np() || insideRunLoop()) return orig(app, sel, mask, until, mode, dequeue);
        if (currentGuest) {
            NSEvent *event = orig(app, sel, mask, [NSDate distantPast], mode, dequeue);
            yieldMainThread();
            return event;
        }
        yieldMainThread();
        return orig(app, sel, mask, game.state == kRunning ? [NSDate distantPast] : until, mode, dequeue);
    }));
    // A game's [NSBundle mainBundle] is its own bundle (CFBundleGetMainBundle is interposed above).
    Method mb = class_getClassMethod([NSBundle class], @selector(mainBundle));
    NSBundle *(*mainBundle)(id, SEL) = (void *)method_getImplementation(mb);
    method_setImplementation(mb, imp_implementationWithBlock(^NSBundle *(id cls) {
        if (game.state != kNone && owner(__builtin_return_address(0)) == &game) return [NSBundle bundleWithPath:@(game.bundle)];
        return mainBundle(cls, @selector(mainBundle));
    }));
}

// How Steam starts a Mac game: -[NSWorkspace launchApplicationAtURL:options:configuration:error:], then the pid of the
// NSRunningApplication it returns (watched with kevent). A prepared game runs in-process from here.
static void hookGameLaunches(void) {
    SEL sel = @selector(launchApplicationAtURL:options:configuration:error:);
    Method m = class_getInstanceMethod([NSWorkspace class], sel);
    typedef NSRunningApplication *(*launch_t)(id, SEL, NSURL *, NSWorkspaceLaunchOptions, NSDictionary *, NSError **);
    launch_t orig = (launch_t)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^NSRunningApplication *(id ws, NSURL *url, NSWorkspaceLaunchOptions options, NSDictionary *config, NSError **error) {
        say("game launch: %s options 0x%lx arguments %s", url.path.UTF8String, (unsigned long)options,
            [config[NSWorkspaceLaunchConfigurationArguments] componentsJoinedByString:@" "].UTF8String);
        NSRunningApplication *app = startGame(url, config);
        if (app) return app;
        if (refuseSpawn("app launch", url.path.UTF8String)) return nil;
        app = orig(ws, sel, url, options, config, error);
        say("  -> launched normally, pid %d", app.processIdentifier);
        return app;
    }));
}

int onehost_main(int argc, char **argv, char **envp, char **apple) {
    char exe[PATH_MAX], path[PATH_MAX];
    uint32_t n = sizeof exe;
    _NSGetExecutablePath(exe, &n);
    strlcpy(steamDir, exe, sizeof steamDir); *strrchr(steamDir, '/') = 0;
    snprintf(guestsDir, sizeof guestsDir, "%s/Library/Application Support/Steam/onehost-guests", getenv("HOME"));
    hostApple = apple;
    // Chromium starts its subprocesses (crashpad, and renderer/GPU if single-process is ever refused) from its own
    // executable path, which is now ours: hand those to the real Steam Helper.
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "--type=", 7)) {
        snprintf(path, sizeof path, "%s/../Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper", steamDir);
        argv[0] = path;
        execv(path, argv);
        return 127;
    }
    if (!poolSlotIsRight()) { say("objc's autorelease pool TLS slot is not %d on this macOS; fibers would corrupt pools", kPoolSlot); return 1; }
    snprintf(path, sizeof path, "%s/steam_osx.onehost.dylib", steamDir);
    say("---- start pid %d, loading %s", getpid(), path);
    guest_main_t steamMain = loadMain(path);
    if (!steamMain) return 1;
    static char steam[PATH_MAX];
    snprintf(steam, sizeof steam, "%s/steam_osx", steamDir);
    argv[0] = steam;   // steam_osx sees its usual argv[0]
    // What Steam.app's bootstrapper hands steam_osx; without them steam_osx sets them and re-execs itself (no exec on iOS).
    char cfg[PATH_MAX], bundle[PATH_MAX];
    snprintf(cfg, sizeof cfg, "%s/steam.cfg", steamDir);
    snprintf(path, sizeof path, "%s/../..", steamDir);
    if (!realpath(path, bundle)) strlcpy(bundle, path, sizeof bundle);
    setenv("STEAM_CLIENT_CONFIG_FILE", cfg, 0);
    setenv("STEAM_APP_BUNDLE_PATH", bundle, 0);
    shareMainThread();
    hookGameLaunches();
    say("calling steam_osx main on the main thread");
    int rc = steamMain(argc, argv, envp, apple);
    say("steam_osx main returned %d", rc);
    return rc;
}
