// Mac check for play/EngineBundle.m: [NSBundle mainBundle] and _NSGetExecutablePath answer calls from one image (a
// stand-in engine, built here) with another folder, resources included; every other caller still gets the real ones.
// clang -Wall -Wextra -fobjc-arc -dynamiclib -DENGINE host/probe/test_engine_bundle.m -framework Foundation -o /tmp/engine.dylib &&
// clang -Wall -Wextra -fobjc-arc -Iplay -Ihost play/EngineBundle.m host/vendor/fishhook.c host/probe/test_engine_bundle.m -framework Foundation -o /tmp/t && /tmp/t /tmp/engine.dylib
// Expect `engine bundle ok`.
#import <Foundation/Foundation.h>
#ifdef ENGINE
#import <mach-o/dyld.h>
#include <string.h>
const char *engine_bundle_path(void) { return NSBundle.mainBundle.bundlePath.fileSystemRepresentation; }
const char *engine_resource(void) {
    return [[NSBundle mainBundle] pathForResource:@"prefix-template" ofType:@"tar.gz"].fileSystemRepresentation ?: "(none)";
}
// Madeira's init_paths(): the folder of the executable, from dirname(_NSGetExecutablePath()).
const char *engine_exe_dir(void) {
    static char buf[1024];
    uint32_t size = sizeof buf;
    if (_NSGetExecutablePath(buf, &size)) return "(too long)";
    *strrchr(buf, '/') = 0;
    return buf;
}
int engine_exe_small(uint32_t *size) {   // the API's contract for a buffer that is too small
    char buf[4];
    *size = sizeof buf;
    return _NSGetExecutablePath(buf, size);
}
#else
#import "EngineBundle.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:[dir stringByAppendingPathComponent:@"prefix-template.tar.gz"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *real = NSBundle.mainBundle.bundlePath;
        void *engine = dlopen(argv[1], RTLD_NOW);
        const char *(*bundlePath)(void) = dlsym(engine, "engine_bundle_path"), *(*resource)(void) = dlsym(engine, "engine_resource");
        const char *(*exeDir)(void) = dlsym(engine, "engine_exe_dir");
        int (*exeSmall)(uint32_t *) = dlsym(engine, "engine_exe_small");
        CHECK(bundlePath && resource && exeDir && exeSmall);
        CHECK([@(bundlePath()) isEqualToString:real]);   // before the redirect: the real one
        char exe[1024];
        uint32_t exeSize = sizeof exe;
        CHECK(_NSGetExecutablePath(exe, &exeSize) == 0);
        NSString *realExe = @(exe);
        CHECK([@(exeDir()) isEqualToString:realExe.stringByDeletingLastPathComponent]);   // before: this binary's folder
        ShackEngineBundleRedirect((const void *)bundlePath, dir);
        NSString *resolved = dir.stringByResolvingSymlinksInPath;
        CHECK([@(bundlePath()).stringByResolvingSymlinksInPath isEqualToString:resolved]);
        CHECK([@(resource()).stringByResolvingSymlinksInPath isEqualToString:[resolved stringByAppendingPathComponent:@"prefix-template.tar.gz"]]);
        CHECK([NSBundle.mainBundle.bundlePath isEqualToString:real]);   // this caller is not the engine
        CHECK([@(exeDir()).stringByResolvingSymlinksInPath isEqualToString:resolved]);   // the engine's init_paths: its folder
        exeSize = sizeof exe;
        CHECK(_NSGetExecutablePath(exe, &exeSize) == 0 && [@(exe) isEqualToString:realExe]);   // this caller still gets the real path
        uint32_t need = 0;
        CHECK(exeSmall(&need) == -1);
        CHECK(need == [dir stringByAppendingPathComponent:@"MacShackPlay"].length + 1);   // path and its NUL
        NSString *dir2 = [dir stringByAppendingString:@"-2"];   // a second call: the last folder wins
        [NSFileManager.defaultManager createDirectoryAtPath:dir2 withIntermediateDirectories:YES attributes:nil error:nil];
        ShackEngineBundleRedirect((const void *)bundlePath, dir2);
        CHECK([@(exeDir()).stringByResolvingSymlinksInPath isEqualToString:dir2.stringByResolvingSymlinksInPath]);
        [NSFileManager.defaultManager removeItemAtPath:dir2 error:nil];
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        printf("engine bundle ok\n");
    }
    return 0;
}
#endif
