// CVDisplayLink over a CADisplayLink on a dedicated run-loop thread. Re-exports CoreVideo.
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <dlfcn.h>

typedef uint32_t CGDirectDisplayID;
typedef struct __CVDisplayLink *CVDisplayLinkRef;
typedef CVReturn (*CVDisplayLinkOutputCallback)(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow,
                                                const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn,
                                                CVOptionFlags *flagsOut, void *displayLinkContext);

// ponytail: 60 until the main thread has answered once; refresh-rate changes are not tracked.
static double PanelFPS(void) {
    static _Atomic double fps;
    if (fps == 0) {
        void (^read)(void) = ^{ fps = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).screen.maximumFramesPerSecond; };
        if (NSThread.isMainThread) read(); else dispatch_async(dispatch_get_main_queue(), read);
    }
    return fps > 0 ? fps : 60;
}
// Capped (the loader's SHACK_FRAME_CAP, then ShackCVSetFrameRate), the cap is the display the game sees and the rate the
// link asks the panel for, as Madeira's ProMotion intent does: with the link at 120 the panel stayed at 120 and a 40 fps
// cap had to hit every third refresh, which a finger on the touch controls broke for a third of the frames (Jackal,
// 2026-10-03). Running links follow a new cap at their next tick (the island menu changes it mid-game).
static _Atomic double gCap = -1;   // fps; 0 = the panel's maximum, -1 = SHACK_FRAME_CAP not read yet
static double CapFPS(void) {
    if (gCap < 0) { const char *cap = getenv("SHACK_FRAME_CAP"); gCap = cap && atoi(cap) > 0 ? atoi(cap) : 0; }
    return gCap;
}
static double MaxFPS(void) { double cap = CapFPS(); return cap > 0 ? cap : PanelFPS(); }

static mach_timebase_info_data_t Timebase(void) {
    static mach_timebase_info_data_t tb; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return tb;
}
// The display rate the game sees: the cap when capped (the rate the links ask for), else the rate a link gets now (120
// on ProMotion with CADisableMinimumFrameDurationOnPhone, 60 in Low Power Mode), from the latest tick's own period.
// Unity times its frames by it (vblanks waited x period): an 8-tick average taken while the panel was still changing
// rate stuck at 120 under a 60 cap, so Tunic waited two ticks a frame (30 fps) and its deltaTime ran at half speed
// (2026-10-04). Exported so libShackCG reports the same number without linking us.
static _Atomic double gMeasuredFPS;
__attribute__((visibility("default"))) double ShackCVRefreshRate(void) {
    double cap = CapFPS(), m = gMeasuredFPS;
    return cap > 0 ? cap : m > 0 ? m : PanelFPS();
}

static uint64_t TicksToNs(uint64_t t) { mach_timebase_info_data_t tb = Timebase(); return (uint64_t)((__uint128_t)t * tb.numer / tb.denom); }
static uint64_t NsToTicks(uint64_t ns) { mach_timebase_info_data_t tb = Timebase(); return (uint64_t)((__uint128_t)ns * tb.denom / tb.numer); }

// Sleeping: links made by code from an image whose path contains gSleeper (the Steam client's, while a game it started
// has the screen) pause their CADisplayLink, so Chromium gets no frames to draw and its thread no wakeups.
static char *gSleeper;   // guarded by @synchronized(gLinks)
static NSHashTable *gLinks;   // every link, weak
static _Atomic uint64_t gTickCount;   // callbacks made, for the host's power line

@interface ShackDisplayLink : NSObject
@end
@implementation ShackDisplayLink {
@public
    CVDisplayLinkOutputCallback _callback; void *_context; CGDirectDisplayID _display;
    id _handler;   // CVDisplayLinkSetOutputHandler's block
    atomic_bool _running; NSThread *_thread;
    char _creator[512];   // image of the code that made the link
    CFRunLoopRef _runLoop;   // the link thread's, while it runs; guarded by @synchronized(self)
    float _rate; BOOL _paused; CADisplayLink *_link;   // tick-thread only   // _thread and the running->thread decision guarded by @synchronized(self)
}
// The rate and pause state the link should have now; on the link's thread.
- (void)apply {
    BOOL sleep;
    @synchronized (gLinks) { sleep = gSleeper && strstr(_creator, gSleeper); }
    if (sleep != _paused) { _paused = sleep; _link.paused = sleep; }
    float want = (float)MaxFPS();
    if (want != _rate) { _rate = want; _link.preferredFrameRateRange = CAFrameRateRangeMake(want, want, want); }
}
- (void)kick {   // apply from any thread
    @synchronized (self) {
        if (!_runLoop) return;
        CFRunLoopPerformBlock(_runLoop, kCFRunLoopDefaultMode, ^{ [self apply]; });
        CFRunLoopWakeUp(_runLoop);
    }
}
- (void)tick:(CADisplayLink *)link {
    [self apply];
    CVDisplayLinkOutputCallback cb = _callback;
    if (!atomic_load(&_running) || !cb || _paused) return;
    double period = link.targetTimestamp - link.timestamp;
    if (period > 0 && CapFPS() == 0) gMeasuredFPS = round(1 / period);
    if (period <= 0) period = 1.0 / ShackCVRefreshRate();
    uint64_t host = mach_absolute_time(), periodNs = (uint64_t)(period * 1e9);
    CVTimeStamp now = {0};
    now.videoTimeScale = 1000000000; now.videoTime = (int64_t)TicksToNs(host); now.hostTime = host;   // hostTime in mach ticks
    now.rateScalar = 1.0; now.videoRefreshPeriod = (int64_t)periodNs;
    now.flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid | kCVTimeStampRateScalarValid | kCVTimeStampVideoRefreshPeriodValid;
    CVTimeStamp out = now;
    out.videoTime += periodNs; out.hostTime += NsToTicks(periodNs);
    CVOptionFlags flagsOut = 0;
    gTickCount++;
    cb((__bridge CVDisplayLinkRef)self, &now, &out, 0, &flagsOut, _context);
}
- (void)run {
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self apply];
    [_link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    @synchronized (self) { _runLoop = CFRunLoopGetCurrent(); }
    for (;;) {
        @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture]; }
        @synchronized (self) { if (!atomic_load(&_running)) { _thread = nil; _runLoop = NULL; break; } }   // Start may revive us before we exit
    }
    [_link invalidate]; _link = nil;   // on its own run-loop thread; breaks the link->self retain
}
- (void)start {
    @synchronized (self) {
        if (atomic_exchange(&_running, true)) return;
        if (_thread) return;   // still draining after a Stop: it sees _running and keeps going
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"ShackCVDisplayLink"; _thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [_thread start];
    }
}
// A paused (sleeping) link never ticks, so its run loop is stopped to notice. A ticking one notices at its next tick and
// stays reusable until then (Chromium stops and starts its link often).
- (void)stop { @synchronized (self) { atomic_store(&_running, false); if (_runLoop && _paused) CFRunLoopStop(_runLoop); } }
@end

static void KickAll(void) {
    NSArray *links;
    @synchronized (gLinks) { links = gLinks.allObjects; }
    for (ShackDisplayLink *l in links) [l kick];
}
// The host's frame cap, live (0 = the panel's maximum).
__attribute__((visibility("default"))) void ShackCVSetFrameRate(double fps) { gCap = fps > 0 ? fps : 0; KickAll(); }
// Pauses the links made by code from images whose path contains `image` (NULL wakes them).
__attribute__((visibility("default"))) void ShackCVSleepLinksOf(const char *image) {
    @synchronized (gLinks) { free(gSleeper); gSleeper = image ? strdup(image) : NULL; }
    KickAll();
}
// Callbacks since the last call; links running and sleeping now.
__attribute__((visibility("default"))) uint64_t ShackCVTakeStats(unsigned *running, unsigned *sleeping) {
    NSArray *links;
    @synchronized (gLinks) { links = gLinks.allObjects; }
    unsigned r = 0, s = 0;
    for (ShackDisplayLink *l in links) if (atomic_load(&l->_running)) { r++; s += l->_paused; }
    if (running) *running = r;
    if (sleeping) *sleeping = s;
    return atomic_exchange(&gTickCount, 0);
}

static CVReturn Create(CGDirectDisplayID display, CVDisplayLinkRef *displayLinkOut, void *caller) {
    ShackDisplayLink *l = [ShackDisplayLink new]; l->_display = display;
    Dl_info info;
    if (dladdr(caller, &info) && info.dli_fname) strlcpy(l->_creator, info.dli_fname, sizeof l->_creator);
    static dispatch_once_t once; dispatch_once(&once, ^{ gLinks = [NSHashTable weakObjectsHashTable]; });
    @synchronized (gLinks) { [gLinks addObject:l]; }
    *displayLinkOut = (CVDisplayLinkRef)CFBridgingRetain(l);
    return kCVReturnSuccess;
}
#define LINK(l) ((__bridge ShackDisplayLink *)(void *)(l))

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *displayLinkOut) {
    return Create(1, displayLinkOut, __builtin_return_address(0));
}
CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef l, CVDisplayLinkOutputCallback callback, void *userInfo) {
    LINK(l)->_context = userInfo; LINK(l)->_callback = callback; return kCVReturnSuccess;
}
// Block form (Godot 4.5): the block rides in the callback's context; the link keeps it alive in _handler.
typedef CVReturn (^CVDisplayLinkOutputHandler)(CVDisplayLinkRef, const CVTimeStamp *, const CVTimeStamp *, CVOptionFlags, CVOptionFlags *);
static CVReturn RunHandler(CVDisplayLinkRef l, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flags, void *ctx) {
    return ((__bridge CVDisplayLinkOutputHandler)ctx)(l, now, out, in, flags);
}
CVReturn CVDisplayLinkSetOutputHandler(CVDisplayLinkRef l, CVDisplayLinkOutputHandler handler) {
    LINK(l)->_handler = [handler copy];
    return CVDisplayLinkSetOutputCallback(l, handler ? RunHandler : NULL, (__bridge void *)LINK(l)->_handler);
}
Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef l) { return atomic_load(&LINK(l)->_running); }
CVReturn CVDisplayLinkStart(CVDisplayLinkRef l) { [LINK(l) start]; return kCVReturnSuccess; }
CVReturn CVDisplayLinkStop(CVDisplayLinkRef l) { [LINK(l) stop]; return kCVReturnSuccess; }
// ponytail: assumes the creator is the only owner (UE never CVDisplayLinkRetains), so release stops the link.
void CVDisplayLinkRelease(CVDisplayLinkRef l) { if (!l) return; [LINK(l) stop]; CFRelease(l); }
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(CVDisplayLinkRef l) { return 1.0 / ShackCVRefreshRate(); }
CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef l) { return LINK(l)->_display; }
CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef l, CGDirectDisplayID displayID) { LINK(l)->_display = displayID; return kCVReturnSuccess; }
CVReturn CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID displayID, CVDisplayLinkRef *displayLinkOut) {
    return Create(displayID, displayLinkOut, __builtin_return_address(0));
}
// Now, in the timestamps the link's callback gets (Chromium reads it between ticks).
CVReturn CVDisplayLinkGetCurrentTime(CVDisplayLinkRef l, CVTimeStamp *outTime) {
    if (!outTime) return kCVReturnInvalidArgument;
    uint64_t host = mach_absolute_time();
    *outTime = (CVTimeStamp){ .videoTimeScale = 1000000000, .videoTime = (int64_t)TicksToNs(host), .hostTime = host, .rateScalar = 1.0,
        .videoRefreshPeriod = (int64_t)(1e9 / ShackCVRefreshRate()),
        .flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid | kCVTimeStampRateScalarValid | kCVTimeStampVideoRefreshPeriodValid };
    return kCVReturnSuccess;
}
CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef l) {
    return (CVTime){ .timeValue = llround(1e6 / ShackCVRefreshRate()), .timeScale = 1000000, .flags = 0 };
}

// ponytail: no OpenGL on iOS (libShackOpenGL fails every context), so the GL texture cache never gets made.
typedef void *CVOpenGLTextureCacheRef, *CVOpenGLTextureRef;
CVReturn CVOpenGLTextureCacheCreate(CFAllocatorRef a, CFDictionaryRef cacheAttrs, void *cglContext, void *cglPixelFormat,
                                    CFDictionaryRef textureAttrs, CVOpenGLTextureCacheRef *cacheOut) {
    if (cacheOut) *cacheOut = NULL;
    return kCVReturnUnsupported;
}
CVReturn CVOpenGLTextureCacheCreateTextureFromImage(CFAllocatorRef a, CVOpenGLTextureCacheRef cache, CVImageBufferRef image,
                                                    CFDictionaryRef attrs, CVOpenGLTextureRef *textureOut) {
    if (textureOut) *textureOut = NULL;
    return kCVReturnUnsupported;
}
void CVOpenGLTextureCacheFlush(CVOpenGLTextureCacheRef cache, CVOptionFlags options) {}
void CVOpenGLTextureCacheRelease(CVOpenGLTextureCacheRef cache) {}
uint32_t CVOpenGLTextureGetName(CVOpenGLTextureRef t) { return 0; }
uint32_t CVOpenGLTextureGetTarget(CVOpenGLTextureRef t) { return 0; }

// ponytail: one display, so the link already follows it.
CVReturn CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(CVDisplayLinkRef l, void *cglContext, void *cglPixelFormat) { return kCVReturnSuccess; }

// Metal.framework's macOS-only device enumeration with hot-plug (Factorio). The guest's Metal load command points
// here; this shim re-exports Metal. A phone has one GPU that never leaves, so the handler is never called.
#import <Metal/Metal.h>
__attribute__((ns_returns_retained)) NSArray *MTLCopyAllDevicesWithObserver(id *observer, id handler) {
    static NSObject *token; static dispatch_once_t once;
    dispatch_once(&once, ^{ token = [NSObject new]; });   // immortal: safe under either ownership convention
    if (observer) *observer = token;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device ? @[device] : @[];
}
void MTLRemoveDeviceObserver(id observer) {}
// The plain enumeration (Unity 2018's Metal device setup looks it up with dlsym and fails without a device).
__attribute__((ns_returns_retained)) NSArray *MTLCopyAllDevices(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device ? @[device] : @[];
}
