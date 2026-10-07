#import <UIKit/UIKit.h>
#import "Probe.h"
#import "ShackLoader.h"
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <os/proc.h>

@implementation Probe
+ (NSArray<NSString *> *)run {
    NSMutableArray *r = [NSMutableArray array];
    [r addObject:[NSString stringWithFormat:@"device: %@ / %@", UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion]];
    [r addObject:[NSString stringWithFormat:@"physical RAM: %.2f GB", NSProcessInfo.processInfo.physicalMemory / 1e9]];
    [r addObject:[NSString stringWithFormat:@"os_proc_available_memory: %.2f GB", os_proc_available_memory() / 1e9]];

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    [r addObject:[NSString stringWithFormat:@"gpu: %@", dev.name]];
    [r addObject:[NSString stringWithFormat:@"supportsBCTextureCompression: %d", dev.supportsBCTextureCompression]];
    [r addObject:[NSString stringWithFormat:@"supports MTLGPUFamilyApple9: %d", [dev supportsFamily:MTLGPUFamilyApple9]]];
    [r addObject:[NSString stringWithFormat:@"supports MTLGPUFamilyMac2: %d", [dev supportsFamily:MTLGPUFamilyMac2]]];

    NSError *err = nil;
    NSURL *lib = [NSBundle.mainBundle URLForResource:@"mac" withExtension:@"metallib"];
    id<MTLLibrary> ml = [dev newLibraryWithURL:lib error:&err];
    id<MTLFunction> fn = [ml newFunctionWithName:@"probe_fill"];
    id<MTLComputePipelineState> pso = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    [r addObject:[NSString stringWithFormat:@"macOS metallib load: %@", pso ? @"OK (pipeline built)" : err.localizedDescription ?: @"FAILED"]];

    NSString *dy = [NSBundle.mainBundle pathForResource:@"machello" ofType:@"dylib"];
    void *h = dlopen(dy.UTF8String, RTLD_NOW);
    const char *(*f)(void) = h ? dlsym(h, "machello") : NULL;
    [r addObject:[NSString stringWithFormat:@"macOS-SDK dylib dlopen: %s", f ? f() : dlerror()]];

    NSString *hello = [NSBundle.mainBundle pathForResource:@"hello" ofType:nil];
    NSString *home = NSTemporaryDirectory();
    NSError *lerr = nil;
    NSNumber *rc = [ShackLoader runGuestMainAtPath:hello home:home argv0:@"/Guest.app/Contents/MacOS/hello" error:&lerr];
    NSString *txt = [NSString stringWithContentsOfFile:[home stringByAppendingPathComponent:@"hello.txt"] encoding:NSUTF8StringEncoding error:nil];
    [r addObject:[NSString stringWithFormat:@"loader self-test: rc=%@ err=%@\n%@", rc, lerr.localizedDescription, txt ?: @"(no hello.txt)"]];
    [[r componentsJoinedByString:@"\n"] writeToFile:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"probe.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return r;
}
@end
