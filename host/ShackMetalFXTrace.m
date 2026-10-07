#import "ShackMetalFXTrace.h"
#import <Foundation/Foundation.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static IMP sNewTemporal, sNewTemporal4;
static _Atomic unsigned sCalls;

static unsigned TraceDescriptor(MTLFXTemporalScalerDescriptor *desc, id device, id compiler, SEL selector) {
    unsigned call = atomic_fetch_add(&sCalls, 1) + 1;
    if (call <= 64) {
        NSLog(@"[MetalFXTrace] call=%u selector=%s descriptor=%@(%p) device=%@(%p) compiler=%@(%p) input=%lux%lu output=%lux%lu color=%lu depth=%lu motion=%lu outputFormat=%lu autoExposure=%d synchronous=%d dynamic=%d minScale=%g maxScale=%g reactive=%d reactiveFormat=%lu",
              call, sel_getName(selector), NSStringFromClass([desc class]), desc,
              NSStringFromClass([device class]), device,
              compiler ? NSStringFromClass([compiler class]) : @"nil", compiler,
              (unsigned long)desc.inputWidth, (unsigned long)desc.inputHeight,
              (unsigned long)desc.outputWidth, (unsigned long)desc.outputHeight,
              (unsigned long)desc.colorTextureFormat, (unsigned long)desc.depthTextureFormat,
              (unsigned long)desc.motionTextureFormat, (unsigned long)desc.outputTextureFormat,
              desc.autoExposureEnabled, desc.requiresSynchronousInitialization,
              desc.inputContentPropertiesEnabled, desc.inputContentMinScale, desc.inputContentMaxScale,
              desc.reactiveMaskTextureEnabled, (unsigned long)desc.reactiveMaskTextureFormat);
    }
    return call;
}

// Both selectors are in the Objective-C new family. Consume exactly the native
// +1 result and return it at +1; an ordinary id-returning C hook would autorelease.
static id __attribute__((ns_returns_retained)) TraceNewTemporal(id self, SEL cmd, id device) {
    unsigned call = TraceDescriptor(self, device, nil, cmd);
    id result = (__bridge_transfer id)((void *(*)(id, SEL, id))sNewTemporal)(self, cmd, device);
    if (call <= 64) NSLog(@"[MetalFXTrace] call=%u result=%@(%p)", call,
                         result ? NSStringFromClass([result class]) : @"nil", result);
    return result;
}

static id __attribute__((ns_returns_retained)) TraceNewTemporal4(id self, SEL cmd, id device, id compiler) {
    unsigned call = TraceDescriptor(self, device, compiler, cmd);
    id result = (__bridge_transfer id)((void *(*)(id, SEL, id, id))sNewTemporal4)(self, cmd, device, compiler);
    if (call <= 64) NSLog(@"[MetalFXTrace] call=%u result=%@(%p)", call,
                         result ? NSStringFromClass([result class]) : @"nil", result);
    return result;
}

void ShackMetalFXTraceInstall(void) {
    const char *value = getenv("SHACK_METALFXLOG");
    if (!value || strcmp(value, "1")) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = MTLFXTemporalScalerDescriptor.class;
        SEL selectors[] = { @selector(newTemporalScalerWithDevice:), @selector(newTemporalScalerWithDevice:compiler:) };
        IMP hooks[] = { (IMP)TraceNewTemporal, (IMP)TraceNewTemporal4 };
        IMP *originals[] = { &sNewTemporal, &sNewTemporal4 };
        for (unsigned i = 0; i < 2; ++i) {
            Method method = class_getInstanceMethod(cls, selectors[i]);
            if (!method) {
                NSLog(@"[MetalFXTrace] unavailable %@ %s", NSStringFromClass(cls), sel_getName(selectors[i]));
                continue;
            }
            *originals[i] = method_getImplementation(method);
            class_replaceMethod(cls, selectors[i], hooks[i], method_getTypeEncoding(method));
            NSLog(@"[MetalFXTrace] observing %@ %s", NSStringFromClass(cls), sel_getName(selectors[i]));
        }
    });
}
