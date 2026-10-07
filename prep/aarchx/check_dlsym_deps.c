// dlsym on a dlopen handle also searches the libraries that image depends on (dlsym(3)). Rewired (Cuphead) opens
// CoreText by its old ApplicationServices path and asks it for CoreFoundation's CFStringGetTypeID.
// clang -arch x86_64 -framework CoreFoundation check_dlsym_deps.c -o /tmp/c && ./ocerz -native /tmp/c   # dlsym deps ok
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    void *ct = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/CoreText.framework/CoreText", RTLD_NOW);
    CFTypeID (*typeID)(void) = ct ? (CFTypeID (*)(void))dlsym(ct, "CFStringGetTypeID") : NULL;
    if (!ct || !typeID || typeID() != CFStringGetTypeID()) {
        printf("dlsym deps FAIL: handle %p, CFStringGetTypeID %p\n", ct, (void *)typeID);
        return 1;
    }
    printf("dlsym deps ok\n");
    return 0;
}
