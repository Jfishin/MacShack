#import "EngineBundle.h"
#import "vendor/fishhook.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

// ponytail: one engine image per process; a second ShackEngineBundleRedirect replaces the first (last wins) and is not thread-safe against the engine running (the old path string leaks on purpose, in case a call is reading it); the _NSGetExecutablePath rebinding stays on the first image; a per-image table if Play ever hosts two engines.
static const void *gEngine;   // the engine image's Mach-O header
static NSBundle *gBundle;     // Windows/engine
static NSBundle *(*gMainBundle)(id, SEL);
static char *gExePath;        // "Windows/engine/MacShackPlay": not a file, only a path whose folder is Windows/engine

// +[NSBundle mainBundle], answered by caller: objc_msgSend jumps here without a frame of its own, so the return address
// is in the caller's image. A tail call from the engine (`return [NSBundle mainBundle];`) or a call via performSelector/
// NSInvocation lands with another return address and gets Play's own bundle; Madeira's calls use the result, so they are not tail calls.
static NSBundle *mainBundle(id self, SEL _cmd) {
    Dl_info info;
    if (gEngine && dladdr(__builtin_return_address(0), &info) && info.dli_fbase == gEngine) return gBundle;
    return gMainBundle(self, _cmd);
}

// _NSGetExecutablePath for the engine alone (fishhook rebinds only its image), with the real API's contract: 0 and the
// path if it fits, else -1 and the size needed (the NUL included).
static int executablePath(char *buf, uint32_t *size) {
    const char *path = gExePath;   // read once: a later redirect may swap it
    uint32_t need = (uint32_t)strlen(path) + 1;
    if (*size < need) { *size = need; return -1; }
    memcpy(buf, path, need);
    return 0;
}

void ShackEngineBundleRedirect(const void *image, NSString *dir) {
    Dl_info info;
    if (!dladdr(image, &info)) return;
    NSBundle *bundle = [NSBundle bundleWithPath:dir];
    if (!bundle) return;   // a bad folder leaves the engine on Play's own bundle, which fails visibly
    gBundle = bundle;
    gEngine = info.dli_fbase;
    gExePath = strdup([dir stringByAppendingPathComponent:@"MacShackPlay"].fileSystemRepresentation);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        gMainBundle = (NSBundle *(*)(id, SEL))method_getImplementation(method);   // before the swap: the new IMP reads it
        method_setImplementation(method, (IMP)mainBundle);
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {   // fishhook wants the engine's slide, which dladdr does not give
            if ((const void *)_dyld_get_image_header(i) != gEngine) continue;
            struct rebinding rebinding = {"_NSGetExecutablePath", (void *)executablePath, NULL};
            rebind_symbols_image((void *)gEngine, _dyld_get_image_vmaddr_slide(i), &rebinding, 1);
            break;
        }
    });
}
