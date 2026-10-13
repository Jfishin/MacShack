#import "ShackTranslated.h"
#import "ShackHooks.h"
#import "ShackLoader.h"
#import "ShackPrep.h"
#import <dlfcn.h>
#import <pthread.h>
#import <sys/mman.h>

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

BOOL ShackStartTranslated(NSString *exePath, NSArray<NSString *> *args, NSError **error) {
    if (!getenv("SHACK_JIT_POOL")) { if (error) *error = [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: @"x86_64 translation needs the JIT pool, and none was prepared."}]; return NO; }
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 64 << 20);
    pthread_t th; int e = pthread_create(&th, &at, translatedThread, (void *)CFBridgingRetain(@[exePath, args]));
    if (e) { if (error) *error = [NSError errorWithDomain:@"MacShack" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pthread_create: %d", e]}]; return NO; }
    return YES;
}
