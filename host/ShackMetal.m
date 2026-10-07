#import "ShackMetal.h"
#import "ShackMetalFXTrace.h"
#import <UIKit/UIKit.h>
#import "ShackHooks.h"
#include <fcntl.h>
#include <sys/stat.h>
#import <objc/runtime.h>
#import "ShackTouchPad.h"
#import <objc/message.h>
#import <os/lock.h>
#import <os/proc.h>
#include <dlfcn.h>

// A macOS renderer uses API that iOS Metal lacks or rejects:
// - MTLStorageModeManaged (CPU/GPU copies kept in sync by didModifyRange:/synchronizeResource:) asserts on iOS.
//   Unified memory makes Shared equivalent, so Managed is rewritten to Shared and the sync calls become no-ops.
// - A few macOS-only queries/setters (isLowPower, textureBarrier, ...) are added where the class lacks them.
static id<MTLDevice> gDevice;
id<MTLDevice> ShackMetalDevice(void) { return gDevice; }

enum { kManaged = 1 };   // MTLStorageModeManaged (macOS-only, so unnamed in the iOS SDK)
static const NSUInteger kManagedOpt = kManaged << MTLResourceStorageModeShift;
static MTLResourceOptions unmanaged(MTLResourceOptions o) { return (o & MTLResourceStorageModeMask) == kManagedOpt ? o & ~MTLResourceStorageModeMask : o; }

// Replace sel on cls with imp, returning the IMP it had (inherited or own).
static IMP swap(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[MacShack] Metal: %@ has no %s", cls, sel_getName(sel)); return NULL; }
    IMP old = method_getImplementation(m);
    class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
    return old;
}
// Add a no-op/zero method where the object's class chain lacks it.
static void addMissing(id obj, const char *sel, IMP imp, const char *types) {
    Class c = [obj class];
    if (class_addMethod(c, sel_registerName(sel), imp, types)) NSLog(@"[MacShack] Metal: added -[%@ %s]", c, sel);
}

// Hooks of new-family selectors (newBuffer..., newTexture..., newLibrary...) must hand the +1 object straight through. A plain
// `id` function under ARC retains and autoreleases it instead, and a game thread that never drains an autorelease pool
// (Hades II: The Forge upload thread, 120 staging buffers a second) then keeps every one alive: 7 GB in 40 s.
#define RETAINED __attribute__((ns_returns_retained))
static IMP oStorage, oTexOpts, oHeapStorage, oHeapOpts, oBufLen, oBufBytes, oBufNoCopy, oHeapBufLen;
static void sStorage(id s, SEL c, MTLStorageMode m) { ((void (*)(id, SEL, MTLStorageMode))oStorage)(s, c, m == (MTLStorageMode)kManaged ? MTLStorageModeShared : m); }
static void sTexOpts(id s, SEL c, MTLResourceOptions o) { ((void (*)(id, SEL, MTLResourceOptions))oTexOpts)(s, c, unmanaged(o)); }
static void sHeapStorage(id s, SEL c, MTLStorageMode m) { ((void (*)(id, SEL, MTLStorageMode))oHeapStorage)(s, c, m == (MTLStorageMode)kManaged ? MTLStorageModeShared : m); }
static void sHeapOpts(id s, SEL c, MTLResourceOptions o) { ((void (*)(id, SEL, MTLResourceOptions))oHeapOpts)(s, c, unmanaged(o)); }

static RETAINED id sBufLen(id s, SEL c, NSUInteger n, MTLResourceOptions o) { return (__bridge_transfer id)((void *(*)(id, SEL, NSUInteger, MTLResourceOptions))oBufLen)(s, c, n, unmanaged(o)); }
static RETAINED id sBufBytes(id s, SEL c, const void *p, NSUInteger n, MTLResourceOptions o) { return (__bridge_transfer id)((void *(*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))oBufBytes)(s, c, p, n, unmanaged(o)); }
static RETAINED id sBufNoCopy(id s, SEL c, void *p, NSUInteger n, MTLResourceOptions o, id d) { return (__bridge_transfer id)((void *(*)(id, SEL, void *, NSUInteger, MTLResourceOptions, id))oBufNoCopy)(s, c, p, n, unmanaged(o), d); }
static RETAINED id sHeapBufLen(id s, SEL c, NSUInteger n, MTLResourceOptions o) { return (__bridge_transfer id)((void *(*)(id, SEL, NSUInteger, MTLResourceOptions))oHeapBufLen)(s, c, n, unmanaged(o)); }

// The Mac RHI gates SM5 (and so the shipped SF_METAL_SM5 shader libraries) on macOS feature sets/families,
// which iOS answers NO. Apple GPUs on iOS run the same shaders, so claim the macOS ones.
static IMP oFeatureSet, oFamily;
static BOOL sFeatureSet(id s, SEL c, NSUInteger fs) {
    // MTLFeatureSet_macOS_GPUFamily1_v1 (10000) .. GPUFamily2_v1 (10005) are the only macOS values; anything above is
    // undefined and must be NO (Hades II probes upward until the first NO).
    BOOL r = fs >= 10000 ? fs <= 10005 : ((BOOL (*)(id, SEL, NSUInteger))oFeatureSet)(s, c, fs);
    static NSMutableSet *seen; static dispatch_once_t once; dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized(seen) { if (![seen containsObject:@(fs)]) { [seen addObject:@(fs)]; NSLog(@"[MacShack] Metal: supportsFeatureSet:%lu -> %d", (unsigned long)fs, r); } }
    const char *trace = getenv("SHACK_METAL_FAMILYLOG");
    if (trace && !strcmp(trace, "1") && fs >= 10000 && fs <= 10005) {
        static unsigned count;
        @synchronized(seen) { if (count++ < 128) {
            BOOL native = ((BOOL (*)(id, SEL, NSUInteger))oFeatureSet)(s, c, fs);
            void *pc = __builtin_return_address(0); Dl_info caller = {0}; dladdr(pc, &caller);
            NSLog(@"[MacShack] Metal family trace: featureSet=%lu native=%d adapted=%d caller=%s+0x%lx",
                  (unsigned long)fs, native, r, caller.dli_fname ?: "?",
                  (unsigned long)((uintptr_t)pc - (uintptr_t)caller.dli_fbase));
        } }
    }
    return r;
}
static BOOL sFamily(id s, SEL c, NSInteger f) {
    BOOL r = (f == 2001 || f == 2002) ? YES : ((BOOL (*)(id, SEL, NSInteger))oFamily)(s, c, f);   // MTLGPUFamilyMac1/Mac2
    static NSMutableSet *seen; static dispatch_once_t once; dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized(seen) { if (![seen containsObject:@(f)]) { [seen addObject:@(f)]; NSLog(@"[MacShack] Metal: supportsFamily:%ld -> %d", (long)f, r); } }
    const char *trace = getenv("SHACK_METAL_FAMILYLOG");
    if (trace && !strcmp(trace, "1") && (f == 2001 || f == 2002)) {
        static unsigned count;
        @synchronized(seen) { if (count++ < 128) {
            BOOL native = ((BOOL (*)(id, SEL, NSInteger))oFamily)(s, c, f);
            void *pc = __builtin_return_address(0); Dl_info caller = {0}; dladdr(pc, &caller);
            NSLog(@"[MacShack] Metal family trace: family=%ld native=%d adapted=%d caller=%s+0x%lx",
                  (long)f, native, r, caller.dli_fname ?: "?",
                  (unsigned long)((uintptr_t)pc - (uintptr_t)caller.dli_fbase));
        } }
    }
    return r;
}

// Older metallibs are stamped "macOS" (platform word 0x8001, no target-OS byte) and iOS refuses them outright.
// The AIR bitcode inside compiles fine for the iOS GPU (the probe's macOS-built metallib loads), so present the
// same bytes with an iOS header. MAP_PRIVATE: only the header page is copied; the file is untouched.
#include <sys/mman.h>
static BOOL retargetHeader(uint8_t *m, size_t n) {   // a macOS-stamped metallib header, rewritten for iOS in place
    if (n < 16 || memcmp(m, "MTLB", 4) || !(m[5] & 0x80)) return NO;
    m[5] &= 0x7F;                // platform word 0x8001 -> 0x0001
    m[11] = 0x82;                // target OS: iOS
    m[12] = 16; m[13] = 0; m[14] = 0; m[15] = 0;   // target OS version 16.0
    return YES;
}
static RETAINED id retargetedLibrary(id dev, NSString *path, NSError **err) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY); if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return nil; }
    uint8_t *m = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0); close(fd);
    if (m == MAP_FAILED) return nil;
    if (!retargetHeader(m, (size_t)st.st_size)) { munmap(m, (size_t)st.st_size); return nil; }
    size_t len = (size_t)st.st_size;
    dispatch_data_t d = dispatch_data_create(m, len, NULL, ^{ munmap(m, len); });
    id lib = [dev newLibraryWithData:d error:err];
    NSLog(@"[MacShack] Metal: retargeted macOS metallib %@ -> %@", path.lastPathComponent, lib ? @"OK" : *err);
    return lib;
}

// The same for libraries handed over as bytes (Hades II reads its shaders from its own files).
static IMP oLibData;
static RETAINED id sLibData(id s, SEL c, dispatch_data_t data, NSError **err) {
    NSError *e = nil;
    id lib = (__bridge_transfer id)((void *(*)(id, SEL, dispatch_data_t, NSError **))oLibData)(s, c, data, &e);
    if (!lib && e.code == MTLLibraryErrorUnsupported && data) {
        size_t n = dispatch_data_get_size(data); uint8_t *m = malloc(n); __block size_t at = 0;
        dispatch_data_apply(data, ^bool(dispatch_data_t r, size_t off, const void *buf, size_t len) { memcpy(m + at, buf, len); at += len; return true; });
        if (retargetHeader(m, n)) {
            dispatch_data_t fixed = dispatch_data_create(m, n, NULL, DISPATCH_DATA_DESTRUCTOR_FREE); m = NULL;
            lib = (__bridge_transfer id)((void *(*)(id, SEL, dispatch_data_t, NSError **))oLibData)(s, c, fixed, &e);
            static _Atomic int logged; if (logged++ < 3) NSLog(@"[MacShack] Metal: retargeted macOS metallib (%zu bytes) -> %@", n, lib ? @"OK" : e);
        }
        free(m);
    }
    if (!lib) NSLog(@"[MacShack] Metal: newLibraryWithData failed: %@", e);
    if (err) *err = e;
    return lib;
}

// Library load failures are the first sign of a shader problem; log them (UE4 shipping builds log nothing).
static IMP oLibFile;
static RETAINED id sLibFile(id s, SEL c, NSString *path, NSError **err) {
    NSError *e = nil;
    char fixed[PATH_MAX];   // Metal opens the file itself, past the case-insensitive open() hook
    if (ShackResolveCase(path.fileSystemRepresentation, fixed, sizeof fixed)) path = @(fixed);
    id lib = (__bridge_transfer id)((void *(*)(id, SEL, NSString *, NSError **))oLibFile)(s, c, path, &e);
    if (!lib && e.code == MTLLibraryErrorUnsupported) lib = retargetedLibrary(s, path, &e);
    if (!lib) NSLog(@"[MacShack] Metal: newLibraryWithFile %@ failed: %@", path, e);
    if (err) *err = e;
    return lib;
}

// Drawable cadence for the watchdog: a steady count means frames are reaching the screen.
#import <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>
static _Atomic unsigned gDrawables;
static IMP oNextDrawable;
static IMP oMaximumDrawableCount;
static void sMaximumDrawableCount(id s, SEL c, NSUInteger count) {
    NSUInteger supported = count > 3 ? 3 : count;
    ((void (*)(id, SEL, NSUInteger))oMaximumDrawableCount)(s, c, supported);
    if (supported != count)
        NSLog(@"[MacShack] Metal: maximumDrawableCount %lu -> %lu", (unsigned long)count,
              (unsigned long)((CAMetalLayer *)s).maximumDrawableCount);
}
// Frame capture: the drawable handed out at frame N is presented by frame N+1, and not reused before N+3
// (triple buffering), so at N+1 its texture holds a finished frame. UE4 turns framebufferOnly off.
static NSString *gCapturePath; static id<MTLTexture> gCaptureTex;
static BOOL gLoggedFramebufferOnly;
static dispatch_queue_t captureQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.macshack.capture", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void writeFrame(id<MTLTexture> t, NSString *path) {
    if (t.framebufferOnly) {   // SDL3 leaves this YES; blitting from such a texture is invalid Metal usage
        if (!gLoggedFramebufferOnly) { gLoggedFramebufferOnly = YES; NSLog(@"[MacShack] capture: skipped, drawable texture is framebufferOnly"); }
        return;
    }
    NSUInteger w = t.width, h = t.height, bpr = w * 4;
    if (t.pixelFormat != MTLPixelFormatBGRA8Unorm && t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) { NSLog(@"[MacShack] capture: pixel format %lu not supported", (unsigned long)t.pixelFormat); return; }
    id<MTLBuffer> buf = [gDevice newBufferWithLength:bpr * h options:MTLResourceStorageModeShared];
    // ponytail: a fresh command queue has no execution-order guarantee against whatever queue the game rendered
    // this texture on (we have no hook into the game's own MTLCommandQueue), so this blit can race the game's
    // last write and tear. Wire in the game's queue here if one becomes reachable.
    id<MTLCommandBuffer> cb = [[gDevice newCommandQueue] commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    NSData *pixels = [NSData dataWithBytes:buf.contents length:bpr * h];   // own copy: encode happens off this (render) thread
    dispatch_async(captureQueue(), ^{
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate((void *)pixels.bytes, w, h, 8, bpr, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        [UIImagePNGRepresentation([UIImage imageWithCGImage:img]) writeToFile:path atomically:YES];
        NSLog(@"[MacShack] captured %lux%lu frame to %@", (unsigned long)w, (unsigned long)h, path.lastPathComponent);
        CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    });
}
void ShackMetalCaptureFrame(NSString *path) { @synchronized(CAMetalLayer.class) { gCapturePath = path; gCaptureTex = nil; } }
// ---- frame cap -----------------------------------------------------------------------------------------------
// Capped, every present becomes presentDrawable:afterMinimumDuration:. iOS presents are always display-synced, so Core
// Animation keeps each frame on glass for a whole number of refreshes and the cadence is the panel's own: no CPU sleep,
// no phase drift against vsync. (macOS honors this call only with CAMetalLayer.displaySyncEnabled, which games turn
// off; that is why THECAP's Mac capper had to sleep on the CPU. iOS has no such switch.) The hold is half a refresh
// short of N refreshes because Core Animation rounds up to the next vsync: exactly N, never N+1 from float error.
// Known limit (Jackal at 40, 2026-10-03): with a finger on the touch controls ~30% of frames take N+1 refreshes although
// each was presented ~49 ms ahead. N-0.95 gave N-1 instead, and absolute presentDrawable:atTime: on the real vsync grid
// slipped as often (and ran its targets ahead into a black screen when early frames were dropped).
static double gHold, gRefresh = 1.0 / 60;   // seconds; gHold 0 = uncapped
static int gCapFPS, gCapN;   // gCapN: refreshes per frame
static BOOL gTwoDrawables;   // see sNextDrawable
// Where each capped frame's time goes (see ShackMetalTakePacing): asked for its drawable, got it, present call.
typedef struct { CFTimeInterval ask, got, present; } FrameTimes;
static char kFrameTimes;
static FrameTimes *frameTimes(id d) {   // created in sNextDrawable, before any other thread sees the drawable
    NSMutableData *m = objc_getAssociatedObject(d, &kFrameTimes);
    if (!m) { m = [NSMutableData dataWithLength:sizeof(FrameTimes)]; objc_setAssociatedObject(d, &kFrameTimes, m, OBJC_ASSOCIATION_RETAIN); }
    return m.mutableBytes;
}
static void capCB(id s, SEL c, id d) {
    frameTimes(d)->present = CACurrentMediaTime();
    ((void (*)(id, SEL, id, CFTimeInterval))objc_msgSend)(s, @selector(presentDrawable:afterMinimumDuration:), d, gHold);
}
static void capCBAt(id s, SEL c, id d, CFTimeInterval t) { capCB(s, c, d); }   // the cap wins over the game's own timing
static void capDrawable(id s, SEL c) {
    frameTimes(s)->present = CACurrentMediaTime();
    ((void (*)(id, SEL, CFTimeInterval))objc_msgSend)(s, @selector(presentAfterMinimumDuration:), gHold);
}
static void capDrawableAt(id s, SEL c, CFTimeInterval t) { capDrawable(s, c); }
static void hookConformers(Protocol *p, SEL sel, IMP imp) {   // every concrete class, whichever one implements sel
    unsigned n = 0; Class *all = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        if (!class_conformsToProtocol(all[i], p)) continue;
        Method m = class_getInstanceMethod(all[i], sel);
        if (m) method_setImplementation(m, imp);
    }
    free(all);
}
// BlackSpace sends Vertex|Object|Mesh (25) to the single-stage Metal 4 timestamp operation. Native validation rejects
// it on both platforms. Vertex represents the pre-raster work; retain the real write and its heap/index/granularity.
static void hookRenderTimestamps(void) {
    const char *enabled = getenv("SHACK_METAL4_TIMESTAMP_STAGE");
    if (!enabled || strcmp(enabled, "1") != 0) return;
    SEL sel = @selector(writeTimestampWithGranularity:afterStage:intoHeap:atIndex:);
    unsigned n = 0, hooked = 0; Class *all = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        // Metal's validation subclass inherits the protocol without declaring it again, and overrides this method.
        Class conformer = all[i];
        while (conformer && !class_conformsToProtocol(conformer, @protocol(MTL4RenderCommandEncoder)))
            conformer = class_getSuperclass(conformer);
        if (!conformer) continue;
        Method m = class_getInstanceMethod(all[i], sel);
        if (!m) continue;
        IMP original = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^(id encoder, MTL4TimestampGranularity granularity,
                                                        MTLRenderStages stage, id heap, NSUInteger index) {
            if (stage == (MTLRenderStages)25) {
                static _Atomic unsigned logged;
                if (logged++ < 8) NSLog(@"[MacShack] Metal: render timestamp stage 25 -> vertex (1), index %lu", (unsigned long)index);
                stage = MTLRenderStageVertex;
            }
            ((void (*)(id, SEL, MTL4TimestampGranularity, MTLRenderStages, id, NSUInteger))original)
                (encoder, sel, granularity, stage, heap, index);
        });
        class_replaceMethod(all[i], sel, replacement, method_getTypeEncoding(m));
        NSLog(@"[MacShack] Metal: timestamp stage adapter on %@", all[i]);
        hooked++;
    }
    free(all);
    NSLog(@"[MacShack] Metal: timestamp stage adapter installed on %u classes", hooked);
}
// Callable again mid-game (the island menu): the hooks read gHold on every present, and libShackCV's links follow.
void ShackMetalSetFrameCap(int fps) {
    static NSInteger hz;   // read on the main thread by the first call (the loader's); later ones may come from any thread
    if (!hz) {
        UIScreen *screen = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).screen;
        hz = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60;
    }
    gRefresh = 1.0 / hz;
    long n = fps <= 0 || fps >= hz ? 0 : lround((double)hz / fps);   // whole refreshes per frame; 0 = uncapped
    gHold = n ? (n - 0.5) / hz : 0; gCapFPS = n ? (int)lround((double)hz / n) : 0; gCapN = (int)n;
    gTwoDrawables = n >= 4;
    // libShackCV's display rate: told directly once it is loaded (no setenv while guest threads may read the environment).
    void (*cvRate)(double) = (void (*)(double))dlsym(RTLD_DEFAULT, "ShackCVSetFrameRate");
    if (cvRate) cvRate(gCapFPS);
    else setenv("SHACK_FRAME_CAP", [NSString stringWithFormat:@"%d", gCapFPS].UTF8String, 1);
    if (!n) { NSLog(@"[MacShack] frame cap off (display %ld Hz)", (long)hz); return; }
    static dispatch_once_t hooked;
    dispatch_once(&hooked, ^{
        hookConformers(@protocol(MTLCommandBuffer), @selector(presentDrawable:), (IMP)capCB);
        hookConformers(@protocol(MTLCommandBuffer), @selector(presentDrawable:atTime:), (IMP)capCBAt);
        hookConformers(@protocol(CAMetalDrawable), @selector(present), (IMP)capDrawable);
        hookConformers(@protocol(CAMetalDrawable), @selector(presentAtTime:), (IMP)capDrawableAt);
    });
    NSLog(@"[MacShack] frame cap %d fps: each frame held %ld refreshes of a %ld Hz display", gCapFPS, n, (long)hz);
}
int ShackMetalFrameCap(void) { return gCapFPS; }

// On-glass pacing from each drawable's presentedTime: frames bucketed by how many refreshes they stayed on screen.
// Uncapped this shows the game's own judder; capped at N refreshes, everything outside bucket N is visible jitter.
static os_unfair_lock gGlassLock = OS_UNFAIR_LOCK_INIT;
static uint64_t gGlass[8];   // [0] dropped, [1..6] refreshes on glass, [7] longer
static CFTimeInterval gLastGlass;
static double gStage[2][4]; static uint64_t gStageN[2], gTouchN[2][2];   // gTouchN[finger on the touch controls][late]   // [kept its slot, late][wait, render, margin, to glass] seconds
static void recordPresented(id<MTLDrawable> d, const FrameTimes *times) {
    CFTimeInterval t = d.presentedTime;
    FrameTimes f = *times;
    os_unfair_lock_lock(&gGlassLock);
    if (t <= 0) gGlass[0]++;   // never reached the screen
    else {
        if (gLastGlass > 0) {
            long r = lround((t - gLastGlass) / gRefresh); gGlass[r < 1 ? 1 : r > 7 ? 7 : r]++;
            if (gCapN && f.got > 0 && f.present > 0) {
                // margin: how long before its slot (the previous frame's glass time + N refreshes) the frame was presented
                int late = r > gCapN; gStageN[late]++; gTouchN[ShackTouchPadTouching() ? 1 : 0][late]++;
                double st[4] = {f.got - f.ask, f.present - f.got, gLastGlass + gCapN * gRefresh - f.present, t - f.present};
                for (int i = 0; i < 4; i++) gStage[late][i] += st[i];
            }
        }
        gLastGlass = t;
    }
    os_unfair_lock_unlock(&gGlassLock);
}
uint64_t ShackMetalAllocatedBytes(void) { return gDevice.currentAllocatedSize; }
NSString *ShackMetalTakePacing(void) {
    uint64_t g[8], sn[2], tn[2][2]; double st[2][4];
    os_unfair_lock_lock(&gGlassLock);
    memcpy(g, gGlass, sizeof g); memset(gGlass, 0, sizeof gGlass);
    memcpy(st, gStage, sizeof st); memset(gStage, 0, sizeof gStage); memcpy(sn, gStageN, sizeof sn); memset(gStageN, 0, sizeof gStageN);
    memcpy(tn, gTouchN, sizeof tn); memset(gTouchN, 0, sizeof gTouchN);
    os_unfair_lock_unlock(&gGlassLock);
    uint64_t shown = 0; for (int i = 1; i < 8; i++) shown += g[i];
    if (!shown) return nil;
    NSMutableString *s = [NSMutableString stringWithFormat:@"pacing %@: %llu frames, refreshes on glass", gCapFPS ? [NSString stringWithFormat:@"cap %d", gCapFPS] : @"uncapped", shown];
    for (int i = 1; i < 8; i++) if (g[i]) [s appendFormat:@" %d%@=%.1f%%", i, i == 7 ? @"+" : @"", 100.0 * g[i] / shown];
    [s appendFormat:@", dropped %llu", g[0]];
    // Average ms per frame, kept its slot / late: blocked in nextDrawable, drawable to present call, margin before its
    // slot (small or negative on late frames = the game presented late; large = the compositor held it), present to glass.
    static const char *stage[] = {"wait", "render", "margin", "to glass"};
    if (sn[0] || sn[1]) {
        [s appendString:@"; ms on time/late:"];
        for (int i = 0; i < 4; i++) [s appendFormat:@" %s %.1f/%.1f", stage[i], sn[0] ? 1e3 * st[0][i] / sn[0] : 0, sn[1] ? 1e3 * st[1][i] / sn[1] : 0];
        for (int k = 1; k >= 0; k--) if (tn[k][0] + tn[k][1])
            [s appendFormat:@"; %s controls %.0f%% late (%llu frames)", k ? "touching" : "not touching", 100.0 * tn[k][1] / (tn[k][0] + tn[k][1]), tn[k][0] + tn[k][1]];
    }
    return s;
}

// A drawable bigger than the panel only costs memory: the compositor scales it down to the screen anyway. A game that
// sizes its Metal view from pixel display modes gets points = pixels and, at 3x, nine times the pixels (Hades II:
// 8604x3960 on a 2868x1320 panel, killed for memory). Clamp to the native size, keeping the aspect ratio.
// Clamped where the size is set, so a game that sizes its render targets from the layer reads back the panel size (Hades
// II allocated 6 GB of targets from 8604x3960), and again before each drawable for layers sized from their bounds.
static CGSize gNativePixels;   // landscape, set on the main thread in ShackMetalFixups
static _Atomic uint64_t gClamps, gSizeSets;
static CGSize clampedSize(CGSize z) {
    CGSize mx = gNativePixels;
    if (mx.width <= 0 || (z.width <= mx.width + 1 && z.height <= mx.height + 1)) return z;
    gClamps++;
    double k = MIN(mx.width / z.width, mx.height / z.height);
    CGSize c = CGSizeMake(floor(z.width * k), floor(z.height * k));
    static _Atomic int logged; if (logged++ < 3) NSLog(@"[MacShack] Metal: drawable %.0fx%.0f larger than the %.0fx%.0f panel, clamped to %.0fx%.0f",
                                                       z.width, z.height, mx.width, mx.height, c.width, c.height);
    return c;
}
static IMP oSetDrawableSize;
static void sSetDrawableSize(id s, SEL c, CGSize z) { gSizeSets++; ((void (*)(id, SEL, CGSize))oSetDrawableSize)(s, c, clampedSize(z)); }
static void clampDrawable(CAMetalLayer *l) {
    CGSize z = l.drawableSize, c = clampedSize(z);
    if (!CGSizeEqualToSize(z, c)) l.drawableSize = c;
}

// One-frame GPU trace (--shack-gputrace in the game's .args): every pass, pipeline and texture of a frame, opened in
// Xcode on the Mac. Spans two drawable acquisitions, so one whole frame lies inside wherever the game takes its drawable.
// Needs MTL_CAPTURE_ENABLED=1 before the device exists (the loader sets it for this flag).
static NSString *gTracePath; static int gTraceLeft;
static void traceStep(void) {
    @synchronized(CAMetalLayer.class) {
        MTLCaptureManager *m = MTLCaptureManager.sharedCaptureManager;
        if (!gTracePath) return;
        if (!m.isCapturing) {
            MTLCaptureDescriptor *d = [MTLCaptureDescriptor new];
            d.captureObject = gDevice; d.destination = MTLCaptureDestinationGPUTraceDocument; d.outputURL = [NSURL fileURLWithPath:gTracePath];
            [NSFileManager.defaultManager removeItemAtPath:gTracePath error:nil];
            NSError *e = nil;
            if ([m startCaptureWithDescriptor:d error:&e]) gTraceLeft = 2;
            else { NSLog(@"[MacShack] GPU trace failed to start: %@", e); gTracePath = nil; }
        } else if (--gTraceLeft == 0) {
            [m stopCapture];
            NSLog(@"[MacShack] GPU trace written to %@", gTracePath.lastPathComponent);
            gTracePath = nil;
        }
    }
}
void ShackMetalCaptureTrace(NSString *path) { @synchronized(CAMetalLayer.class) { gTracePath = path; } }

static id sNextDrawable(id s, SEL c) {
    atomic_fetch_add(&gDrawables, 1);
    static atomic_bool firstFrame;   // the launch splash (GameOverlay.swift) waits for the game to draw
    if (!atomic_exchange(&firstFrame, true)) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"ShackGameFirstFrame" object:nil];
    });
    static char kDrew;   // each layer's first frame: a game started from Big Picture draws on a layer of its own (ShackHooks)
    if (!objc_getAssociatedObject(s, &kDrew)) {
        objc_setAssociatedObject(s, &kDrew, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"ShackLayerFirstFrame" object:nil]; });
    }
    clampDrawable(s);
    // Capped at 4+ refreshes (30 fps on 120 Hz), two drawables: a third would only queue an extra finished frame (one more
    // cap interval of input lag). At 2 refreshes it cannot hold: the next frame's drawable frees only once the last one
    // is on glass, and rendering plus compositing then misses the second vsync (Big Hops capped 60: 3 refreshes 86%,
    // 2 refreshes never, a flat 40 fps). ponytail: 3 refreshes (40 fps) untested, left on the game's own count.
    if (gTwoDrawables && ((CAMetalLayer *)s).maximumDrawableCount != 2) ((CAMetalLayer *)s).maximumDrawableCount = 2;
    if (gTracePath) traceStep();
    CFTimeInterval ask = CACurrentMediaTime();
    id<CAMetalDrawable> d = ((id (*)(id, SEL))oNextDrawable)(s, c);
    FrameTimes *f = d ? frameTimes(d) : NULL;
    if (f) { f->ask = ask; f->got = CACurrentMediaTime(); }
    // The record, not the drawable: the handler's argument need not be the object nextDrawable returned.
    NSData *times = d ? objc_getAssociatedObject(d, &kFrameTimes) : nil;
    [d addPresentedHandler:^(id<MTLDrawable> x) { recordPresented(x, times.bytes); }];
    static _Atomic uint64_t lastSize;   // log each new drawable size once (w << 32 | h)
    CGSize z = ((CAMetalLayer *)s).drawableSize; uint64_t wh = (uint64_t)z.width << 32 | (uint32_t)z.height;
    if (atomic_exchange(&lastSize, wh) != wh) {
        CAMetalLayer *l = s;
        NSLog(@"[MacShack] Metal: drawable %.0fx%.0f (layer opaque %d, presentsWithTransaction %d, %lu drawables)", z.width, z.height,
              l.opaque, l.presentsWithTransaction, (unsigned long)l.maximumDrawableCount);
    }
    if (gCapturePath) @synchronized(CAMetalLayer.class) {
        if (gCaptureTex) { writeFrame(gCaptureTex, gCapturePath); gCapturePath = nil; gCaptureTex = nil; }
        else gCaptureTex = d.texture;
    }
    return d;
}
unsigned ShackMetalTakeDrawableCount(void) { return atomic_exchange(&gDrawables, 0); }

// GPU busy time for the minute line: the union of every command buffer's GPU interval. Near 100% = GPU-bound (fewer
// pixels helps); low while frames are slow = a CPU thread is the limit.
static IMP oCommit;
static os_unfair_lock gGPULock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval gGPUBusy, gGPULastEnd;
static void sCommit(id<MTLCommandBuffer> s, SEL c) {
    [s addCompletedHandler:^(id<MTLCommandBuffer> b) {
        CFTimeInterval start = b.GPUStartTime, end = b.GPUEndTime;
        os_unfair_lock_lock(&gGPULock);
        if (end > gGPULastEnd && end > start) { gGPUBusy += end - MAX(start, gGPULastEnd); gGPULastEnd = end; }
        os_unfair_lock_unlock(&gGPULock);
    }];
    ((void (*)(id, SEL))oCommit)(s, c);
}
double ShackMetalTakeGPUBusy(void) {
    os_unfair_lock_lock(&gGPULock); CFTimeInterval b = gGPUBusy; gGPUBusy = 0; os_unfair_lock_unlock(&gGPULock);
    return b;
}

// GPU memory budget. On a Mac, recommendedMaxWorkingSetSize is VRAM-like headroom beside the game's own memory; on iOS the
// GPU and the game share the app's one memory limit (~8.5 GB here), yet the device reports ~8 GB. Engines size pools from
// it (Hades II: "VRAM 8192 MB", then ran the process out of memory; UE4's texture pool is 70% of it), so report a share
// of what the app actually has. ponytail: 35% of the memory available at launch; tune if a game starves or still bloats.
// Big allocations, logged (first 40): where a game's GPU memory goes.
static IMP oNewHeap, oNewTex;
static RETAINED id sNewHeap(id s, SEL c, MTLHeapDescriptor *d) {
    static _Atomic int n; if (n++ < 12) NSLog(@"[MacShack] Metal: heap %lu MB type %ld storage %lu", (unsigned long)(d.size >> 20), (long)d.type, (unsigned long)d.storageMode);
    return (__bridge_transfer id)((void *(*)(id, SEL, id))oNewHeap)(s, c, d);
}
static RETAINED id sNewTex(id s, SEL c, MTLTextureDescriptor *d) {
    id t = (__bridge_transfer id)((void *(*)(id, SEL, id))oNewTex)(s, c, d);
    NSUInteger bytes = t ? [(id<MTLTexture>)t allocatedSize] : 0;
    static _Atomic int n; if (bytes >= (32u << 20) && n++ < 40)
        NSLog(@"[MacShack] Metal: texture %lux%lux%lu fmt %lu mips %lu array %lu usage %lu = %lu MB", (unsigned long)d.width, (unsigned long)d.height,
              (unsigned long)d.depth, (unsigned long)d.pixelFormat, (unsigned long)d.mipmapLevelCount, (unsigned long)d.arrayLength, (unsigned long)d.usage, (unsigned long)(bytes >> 20));
    return t;
}


static uint64_t gGPUBudget;
static IMP oWorkingSet;
static uint64_t sWorkingSet(id s, SEL c) { uint64_t real = ((uint64_t (*)(id, SEL))oWorkingSet)(s, c); return gGPUBudget && gGPUBudget < real ? gGPUBudget : real; }

static BOOL retNO(id s, SEL c) { return NO; }
static void nop(id s, SEL c) {}
static void nop1(id s, SEL c, id a) {}
static void nopB(id s, SEL c, BOOL f) {}
static void nopRange(id s, SEL c, NSRange r) {}
static void nopSyncTex(id s, SEL c, id t, NSUInteger slice, NSUInteger level) {}

void ShackMetalFixups(void) {
    ShackMetalFXTraceInstall();
    CGSize nb = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).screen.nativeBounds.size;
    gNativePixels = CGSizeMake(MAX(nb.width, nb.height), MIN(nb.width, nb.height));   // games are landscape
    gDevice = MTLCreateSystemDefaultDevice();
    if (!gDevice) return;
    Class dev = [gDevice class];
    addMissing(gDevice, "setShouldMaximizeConcurrentCompilation:", (IMP)nopB, "v@:B");
    addMissing(gDevice, "shouldMaximizeConcurrentCompilation", (IMP)retNO, "B@:");
    addMissing(gDevice, "isLowPower", (IMP)retNO, "B@:");
    addMissing(gDevice, "isHeadless", (IMP)retNO, "B@:");
    addMissing(gDevice, "isRemovable", (IMP)retNO, "B@:");
    addMissing(gDevice, "isDepth24Stencil8PixelFormatSupported", (IMP)retNO, "B@:");

    gGPUBudget = (uint64_t)(os_proc_available_memory() * 0.35);
    oWorkingSet = swap(dev, @selector(recommendedMaxWorkingSetSize), (IMP)sWorkingSet);
    oNewHeap = swap(dev, @selector(newHeapWithDescriptor:), (IMP)sNewHeap);
    oNewTex = swap(dev, @selector(newTextureWithDescriptor:), (IMP)sNewTex);
    NSLog(@"[MacShack] Metal: GPU budget %llu MB (device reports %llu MB)", gGPUBudget >> 20, ((uint64_t (*)(id, SEL))oWorkingSet)(gDevice, @selector(recommendedMaxWorkingSetSize)) >> 20);
    oFeatureSet = swap(dev, @selector(supportsFeatureSet:), (IMP)sFeatureSet);
    oFamily = swap(dev, @selector(supportsFamily:), (IMP)sFamily);
    oNextDrawable = swap(CAMetalLayer.class, @selector(nextDrawable), (IMP)sNextDrawable);
    oMaximumDrawableCount = swap(CAMetalLayer.class, @selector(setMaximumDrawableCount:), (IMP)sMaximumDrawableCount);
    oSetDrawableSize = swap(CAMetalLayer.class, @selector(setDrawableSize:), (IMP)sSetDrawableSize);
    hookRenderTimestamps();
    oCommit = swap([[gDevice newCommandQueue] commandBuffer].class, @selector(commit), (IMP)sCommit);   // the device's concrete class
    oLibFile =swap(dev, @selector(newLibraryWithFile:error:), (IMP)sLibFile);
    oLibData = swap(dev, @selector(newLibraryWithData:error:), (IMP)sLibData);
    oBufLen = swap(dev, @selector(newBufferWithLength:options:), (IMP)sBufLen);
    oBufBytes = swap(dev, @selector(newBufferWithBytes:length:options:), (IMP)sBufBytes);
    oBufNoCopy = swap(dev, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)sBufNoCopy);
    Class td = [[MTLTextureDescriptor new] class], hd = [[MTLHeapDescriptor new] class];
    oStorage = swap(td, @selector(setStorageMode:), (IMP)sStorage);
    oTexOpts = swap(td, @selector(setResourceOptions:), (IMP)sTexOpts);
    oHeapStorage = swap(hd, @selector(setStorageMode:), (IMP)sHeapStorage);
    oHeapOpts = swap(hd, @selector(setResourceOptions:), (IMP)sHeapOpts);

    // Live objects to learn the concrete classes of buffers, heaps and encoders.
    id<MTLBuffer> buf = [gDevice newBufferWithLength:16 options:MTLResourceStorageModeShared];
    addMissing(buf, "didModifyRange:", (IMP)nopRange, "v@:{_NSRange=QQ}");
    MTLHeapDescriptor *h = [MTLHeapDescriptor new]; h.size = 1 << 16; h.storageMode = MTLStorageModePrivate;
    id<MTLHeap> heap = [gDevice newHeapWithDescriptor:h];
    if (heap) oHeapBufLen = swap([heap class], @selector(newBufferWithLength:options:), (IMP)sHeapBufLen);
    NSLog(@"[MacShack] Metal: BC textures %@, ASTC %@", gDevice.supportsBCTextureCompression ? @"yes" : @"no", [gDevice supportsFamily:MTLGPUFamilyApple2] ? @"yes" : @"no");
    id<MTLCommandBuffer> cb = [[gDevice newCommandQueue] commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    addMissing(blit, "synchronizeResource:", (IMP)nop1, "v@:@");
    addMissing(blit, "synchronizeTexture:slice:level:", (IMP)nopSyncTex, "v@:@QQ");
    [blit endEncoding];
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    t.usage = MTLTextureUsageRenderTarget; t.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [gDevice newTextureWithDescriptor:t];
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    addMissing(re, "textureBarrier", (IMP)nop, "v@:");
    [re endEncoding];
}
