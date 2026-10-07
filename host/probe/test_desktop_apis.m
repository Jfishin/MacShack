// Build as an arm64 macOS app with Steam/FMOD test bundle copies in Contents/PlugIns.
// Prepare/launch on iPhone to verify desktop identity and executable URL compatibility.
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        CFStringEncoding encoding = 0;
        CFStringRef name = SCDynamicStoreCopyComputerName(NULL, &encoding);
        NSLog(@"[CompatProbe] computerName nonnull=%d typeOK=%d encoding=%u", name != NULL,
              name && CFGetTypeID(name) == CFStringGetTypeID(), (unsigned)encoding);
        if (name) CFRelease(name);
        NSString *app = @(argv[0]);
        for (int i = 0; i < 3; i++) app = app.stringByDeletingLastPathComponent;
        for (NSString *plugin in @[@"steam_api", @"fmodstudio"]) {
            NSString *path = [app stringByAppendingFormat:@"/Contents/PlugIns/%@.bundle", plugin];
            NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
            CFBundleRef bundle = CFBundleCreate(NULL, (__bridge CFURLRef)url);
            CFURLRef executable = bundle ? CFBundleCopyExecutableURL(bundle) : NULL;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
            NSLog(@"[CompatProbe] %@ bundleCreated=%d executableURL=%@ desktopExecutable=%@", plugin, bundle != NULL,
                  (__bridge NSURL *)executable, info[@"CFBundleExecutable"]);
            if (executable) {
                void *library = dlopen([(__bridge NSURL *)executable fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
                const char *symbol = [plugin isEqual:@"steam_api"] ? "SteamInternal_SteamAPI_Init" : "FMOD5_Memory_GetStats";
                void *function = library ? dlsym(library, symbol) : NULL;
                const char *failure = function ? NULL : dlerror();
                NSLog(@"[CompatProbe] %@ loaded=%d symbol=%s found=%d error=%s", plugin, library != NULL,
                      symbol, function != NULL, failure ?: "none");
                CFRelease(executable);
            }
            if (bundle) CFRelease(bundle);
        }
        NSLog(@"[CompatProbe] complete");
    }
    return 0;
}
