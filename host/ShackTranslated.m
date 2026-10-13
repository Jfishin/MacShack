#import "ShackTranslated.h"
#import "ShackHooks.h"
#import "ShackLoader.h"
#import "ShackPrep.h"
#import "vendor/fishhook.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sys/mman.h>

// Intel games: AArchX (vendor/AArchX, libOcerz.dylib; prep/aarchx/README.md) translates the original x86_64
// executable from Documents/Games. Its bridged calls open the same libraries prep maps arm64 games to.
// libOcerz: linked by MacShack; MacShack Play loads it only for an Intel game, as its 86 MB of data would otherwise sit
// in the address space Play keeps for a Windows program's JIT pool (MadeiraEngine.m).
static void *ocerzSymbol(const char *name) {
    static void *lib;
    if (!lib) lib = dlopen("@rpath/libOcerz.dylib", RTLD_NOW | RTLD_GLOBAL);
    return lib ? dlsym(lib, name) : NULL;
}

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
    int (*ocerzMain)(int, char **) = (int (*)(int, char **))ocerzSymbol("ocerz_main");
    void (*setHostOpen)(void *(*)(const char *)) = (void (*)(void *(*)(const char *)))ocerzSymbol("ocerz_bridge_set_host_open");
    void (*setHostSymbol)(void *(*)(const char *)) = (void (*)(void *(*)(const char *)))ocerzSymbol("ocerz_bridge_set_host_symbol");
    if (!ocerzMain || !setHostOpen || !setHostSymbol) { NSLog(@"[MacShack] AArchX (libOcerz) did not load: %s", dlerror()); return 127; }
    setHostOpen(ocerzHostOpen);
    setHostSymbol(ShackHookForGuestSymbol);   // game bundle identity, case-insensitive paths
    int argc = 3 + (int)args.count;
    char **argv = calloc((size_t)argc + 1, sizeof *argv);   // lives for the process
    argv[0] = strdup("ocerz"); argv[1] = strdup("-native"); argv[2] = strdup(exePath.fileSystemRepresentation);
    for (NSUInteger i = 0; i < args.count; i++) argv[3 + i] = strdup(args[i].UTF8String);
    return ocerzMain(argc, argv);   // runs the guest's main on this thread, as ShackStartGuest does
}

static void *translatedThread(void *arg) {
    NSArray *exeAndArgs = CFBridgingRelease(arg);
    pthread_setname_np("guest-main");
    int rc = ShackRunTranslated(exeAndArgs[0], exeAndArgs[1]);
    NSLog(@"[MacShack] translated guest returned %d", rc);
    ShackGuestEnded(rc);
    return NULL;
}

BOOL ShackStartTranslated(NSString *exePath, NSArray<NSString *> *args, NSError **error) {
    if (!getenv("SHACK_JIT_POOL")) { if (error) *error = [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: @"x86_64 translation needs the JIT pool, and none was prepared."}]; return NO; }
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64 << 20);
    pthread_t th; int e = pthread_create(&th, &at, translatedThread, (void *)CFBridgingRetain(@[exePath, args]));
    if (e) { if (error) *error = [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pthread_create: %d", e]}]; return NO; }
    return YES;
}

// A translated game's Steam API (Valve's x86 steamclient, translated like the game): AArchX's own handlers of a few
// calls (variadic, or taking a command line) call libOcerz's imports, rebound here to libShackSteamClient's in-process
// IPC; the game's code reaches the host through AArchX's symbol lookup, answered by ShackTranslatedSteamSymbol.
static const void *gShimBase;
BOOL ShackTranslatedSteamUse(void *shim) {
    Dl_info d;
    if (!shim || !dladdr(dlsym(shim, "semget"), &d) || !ocerzSymbol("ocerz_main")) return NO;   // libOcerz loaded: its imports are rebound
    gShimBase = d.dli_fbase;
    struct rebinding r[] = {{"sem_open", dlsym(shim, "sem_open"), NULL}, {"shm_open", dlsym(shim, "shm_open"), NULL},
                            {"semctl", dlsym(shim, "semctl"), NULL}, {"popen", dlsym(shim, "popen"), NULL},
                            {"pclose", dlsym(shim, "pclose"), NULL}};
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (strstr(_dyld_get_image_name(i), "/libOcerz.dylib"))
            rebind_symbols_image((void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), r, sizeof r / sizeof *r);
    return YES;
}
// The calls Valve's x86 steamclient made in a session on the Mac (OCERZ_BRIDGELOG_MATCH): Mach look-ups, SysV and POSIX
// semaphores. libShackSteamClient's stubs (what iOS lacks) only when nothing else in the process defines the name: the
// shims (GL, CGL) come first.
void *ShackTranslatedSteamSymbol(void *shim, const char *name) {
    if (!gShimBase) return NULL;
    static const char *const ipc[] = {"bootstrap_look_up", "bootstrap_check_in", "semget", "semop", "sem_close", "sem_unlink",
                                      "sem_wait", "sem_trywait", "sem_post", "shm_unlink", "bind", "connect"};
    for (size_t i = 0; i < sizeof ipc / sizeof *ipc; i++)
        if (!strcmp(name, ipc[i])) { fprintf(stderr, "[MacShack] the Intel game's %s: Steam's answer\n", name); return dlsym(shim, name); }
    Dl_info d;
    void *own = dlsym(shim, name);   // not logged: dozens of AppKit constants; a stub logs its first call
    return own && dladdr(own, &d) && d.dli_fbase == gShimBase && dlsym(RTLD_DEFAULT, name) == own ? own : NULL;
}
