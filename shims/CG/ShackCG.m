// CGDisplay* over the one iOS screen. Re-exports CoreGraphics.
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import "../ShackDisplay.h"

typedef uint32_t CGDirectDisplayID;
typedef struct CGDisplayMode *CGDisplayModeRef;
typedef uint32_t CGDisplayFadeReservationToken;
typedef float CGDisplayBlendFraction, CGDisplayFadeInterval, CGDisplayReservationInterval;
typedef uint32_t CGDisplayChangeSummaryFlags;
typedef void (*CGDisplayReconfigurationCallBack)(CGDirectDisplayID, CGDisplayChangeSummaryFlags, void *);

// The AppKit shim's NSScreen (loaded before us by the guest's link order) caches the metrics; we don't link it.
@protocol ShackScreen <NSObject>
+ (id<ShackScreen>)mainScreen; - (CGRect)frame; - (CGFloat)backingScaleFactor;
@end

static UIScreen *MainUIScreen(void) { return ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).screen; }

static void ScreenMetrics(CGSize *points, CGFloat *scale) {
    if (ShackVirtualDisplaySize(points)) { *scale = 1; return; }
    id<ShackScreen> s = [(Class<ShackScreen>)NSClassFromString(@"NSScreen") mainScreen];
    if (s) { *points = s.frame.size; *scale = s.backingScaleFactor; return; }
    __block CGRect b = CGRectZero; __block CGFloat sc = 1;
    void (^read)(void) = ^{ UIScreen *u = MainUIScreen(); b = u.bounds; sc = u.nativeScale; };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    *points = b.size; *scale = sc;
}

// ponytail: 60 until the main thread has answered once; refresh-rate changes are not tracked.
static double MaxFPS(void) {
    static _Atomic double fps;
    if (fps == 0) {
        void (^read)(void) = ^{ fps = MainUIScreen().maximumFramesPerSecond; };
        if (NSThread.isMainThread) read(); else dispatch_async(dispatch_get_main_queue(), read);
    }
    return fps > 0 ? fps : 60;
}
// Same number CVDisplayLink reports (libShackCV measures the real tick rate); screen maximum if CV isn't loaded.
static double RefreshRate(void) {
    static double (*cv)(void); static dispatch_once_t once;
    dispatch_once(&once, ^{ cv = (double (*)(void))dlsym(RTLD_DEFAULT, "ShackCVRefreshRate"); });
    return cv ? cv() : MaxFPS();
}

@interface ShackDisplayMode : NSObject
@property size_t width, height, pixelWidth, pixelHeight;   // points, as on macOS, and the pixels behind them
@end
@implementation ShackDisplayMode
@end

#define MODE(m) ((__bridge ShackDisplayMode *)(void *)(m))

CGDirectDisplayID CGMainDisplayID(void) { return 1; }
CGError CGGetActiveDisplayList(uint32_t maxDisplays, CGDirectDisplayID *activeDisplays, uint32_t *displayCount) {
    if (activeDisplays && maxDisplays) activeDisplays[0] = 1;
    if (displayCount) *displayCount = (activeDisplays && !maxDisplays) ? 0 : 1;
    return kCGErrorSuccess;
}
int CGSMainConnectionID(void) { return 1; }   // Godot 4 (window blur via private CGS calls it looks up with dlsym); ponytail: no WindowServer
CGRect CGDisplayBounds(CGDirectDisplayID display) { CGSize p; CGFloat s; ScreenMetrics(&p, &s); return (CGRect){CGPointZero, p}; }
size_t CGDisplayPixelsWide(CGDirectDisplayID display) { CGSize p; CGFloat s; ScreenMetrics(&p, &s); return (size_t)p.width; }   // points: macOS reports the mode size on Retina
size_t CGDisplayPixelsHigh(CGDirectDisplayID display) { CGSize p; CGFloat s; ScreenMetrics(&p, &s); return (size_t)p.height; }
CGSize CGDisplayScreenSize(CGDirectDisplayID display) {   // millimetres
    CGSize p; CGFloat s; ScreenMetrics(&p, &s);
    return CGSizeMake(p.width / 163.0 * 25.4, p.height / 163.0 * 25.4);   // ponytail: nominal 163 pt/inch
}
uint32_t CGDisplayModelNumber(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplayVendorNumber(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplaySerialNumber(CGDirectDisplayID display) { return 0; }

// Modes as macOS reports them on a Retina screen. The current mode is the HiDPI one: width/height in points (956x440),
// pixel width/height behind them (2868x1320); a game that sizes its window from the mode gets a screen-sized window.
// The list adds 1x modes (points == pixels) at native, 3/4, 2/3 and 1/2, so UE4 can still offer 2868x1320 in its menu.
// (Until 2026-09-25 every mode was pixel-sized; Hades II then made a 2868x1320-point window, a 9x drawable, and ran out
// of memory.)
static ShackDisplayMode *RetinaMode(void) {
    CGSize p; CGFloat s; ScreenMetrics(&p, &s);
    ShackDisplayMode *m = [ShackDisplayMode new];
    m.width = (size_t)lround(p.width); m.height = (size_t)lround(p.height);
    m.pixelWidth = (size_t)lround(p.width * s); m.pixelHeight = (size_t)lround(p.height * s);
    return m;
}
static ShackDisplayMode *PixelMode(int num, int den) {   // 1x: num/den of native, even dimensions
    CGSize p; CGFloat s; ScreenMetrics(&p, &s);
    ShackDisplayMode *m = [ShackDisplayMode new];
    m.pixelWidth = m.width = (size_t)lround(p.width * s) * num / den & ~(size_t)1;
    m.pixelHeight = m.height = (size_t)lround(p.height * s) * num / den & ~(size_t)1;
    return m;
}
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) { return (CGDisplayModeRef)CFBridgingRetain(RetinaMode()); }
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options) {
    if (ShackVirtualDisplaySize(NULL)) return CFBridgingRetain(@[RetinaMode()]);
    return CFBridgingRetain(@[RetinaMode(), PixelMode(1, 1), PixelMode(3, 4), PixelMode(2, 3), PixelMode(1, 2)]);
}
CGError CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options) {
    NSLog(@"[ShackCG] CGDisplaySetDisplayMode ignored (%zux%zu)", mode ? MODE(mode).width : 0, mode ? MODE(mode).height : 0);
    return kCGErrorSuccess;
}
size_t CGDisplayModeGetWidth(CGDisplayModeRef mode) { return mode ? MODE(mode).width : 0; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef mode) { return mode ? MODE(mode).height : 0; }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode) { return mode ? MODE(mode).pixelWidth : 0; }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode) { return mode ? MODE(mode).pixelHeight : 0; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode) { return mode ? RefreshRate() : 0; }   // live, may be measured after the copy
bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode) { return mode != NULL; }
CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef mode) { if (mode) CFRetain(mode); return mode; }
void CGDisplayModeRelease(CGDisplayModeRef mode) { if (mode) CFRelease(mode); }

// ponytail: one screen that never reconfigures, so callbacks are accepted and never fire.
CGError CGDisplayRegisterReconfigurationCallback(CGDisplayReconfigurationCallBack cb, void *userInfo) { return kCGErrorSuccess; }
CGError CGDisplayRemoveReconfigurationCallback(CGDisplayReconfigurationCallBack cb, void *userInfo) { return kCGErrorSuccess; }

// ponytail: touch screen, no pointer to hide or warp.
CGError CGDisplayHideCursor(CGDirectDisplayID display) { return kCGErrorSuccess; }
CGError CGDisplayShowCursor(CGDirectDisplayID display) { return kCGErrorSuccess; }
boolean_t CGCursorIsVisible(void) { return 1; }
CGError CGWarpMouseCursorPosition(CGPoint p) { return kCGErrorSuccess; }
CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { return kCGErrorSuccess; }

// ponytail: no display fades; the reservation is a token that does nothing.
CGError CGAcquireDisplayFadeReservation(CGDisplayReservationInterval seconds, CGDisplayFadeReservationToken *token) {
    if (token) *token = 1; return kCGErrorSuccess;
}
CGError CGDisplayFade(CGDisplayFadeReservationToken token, CGDisplayFadeInterval duration, CGDisplayBlendFraction startBlend,
                      CGDisplayBlendFraction endBlend, float red, float green, float blue, boolean_t synchronous) { return kCGErrorSuccess; }
CGError CGReleaseDisplayFadeReservation(CGDisplayFadeReservationToken token) { return kCGErrorSuccess; }

CFDictionaryRef CGSessionCopyCurrentDictionary(void) {
    return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

// ponytail: event-source state is not tracked; Unity reads keys and mouse from NSEvents, these only resync modifiers.
bool CGEventSourceKeyState(int32_t stateID, uint16_t key) { return false; }
bool CGEventSourceButtonState(int32_t stateID, uint32_t button) { return false; }
uint64_t CGEventSourceFlagsState(int32_t stateID) { return 0; }
void *CGEventCreateMouseEvent(void *source, uint32_t type, CGPoint p, uint32_t button) { return NULL; }   // no synthetic events
// ponytail: 0 until relative mouse (pointer lock) matters; NSEvent deltaX/deltaY carry the real motion.
void CGGetLastMouseDelta(int32_t *dx, int32_t *dy) { if (dx) *dx = 0; if (dy) *dy = 0; }

boolean_t CGDisplayIsBuiltin(CGDirectDisplayID display) { return 1; }
uint32_t CGDisplayIOServicePort(CGDirectDisplayID display) { return 0; }   // MACH_PORT_NULL: no IOKit display service
uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID display) { return 1; }
CGDirectDisplayID CGOpenGLDisplayMaskToDisplayID(uint32_t mask) { return CGMainDisplayID(); }
// GLFW's Cocoa backend (raylib). Its init fails on a NULL event source; it only sets the suppression interval and
// releases it, so any CF object will do.
CFTypeRef CGEventSourceCreate(int32_t stateID) { return CFDataCreate(NULL, NULL, 0); }
// The "current state" event a game creates to read the pointer (Unity's mouse position). ponytail: (0,0); input
// arrives as NSEvents, so only a game that polls this for its cursor would want the last touch here.
CFTypeRef CGEventCreate(CFTypeRef source) { return CFDataCreate(NULL, NULL, 0); }
CGPoint CGEventGetLocation(CFTypeRef event) { return CGPointZero; }
// Steam's on-screen keyboard (steamclient on its IPC thread) types into the app in front by posting key-downs: key code 0
// with each character as the event's Unicode string, or Return (36), Delete (51) and the arrows (123-126) alone. The
// event is a CF object (a NULL one crashed MacShack in CFRelease, 2026-10-04); libShackAppKit delivers it as an NSEvent.
typedef struct { uint16_t keycode; bool down; uint8_t length; UniChar chars[20]; } KeyEvent;
static KeyEvent *keyEvent(CFTypeRef e) {   // NULL unless e came from CGEventCreateKeyboardEvent
    return e && CFGetTypeID(e) == CFDataGetTypeID() && CFDataGetLength(e) == sizeof(KeyEvent) ? (KeyEvent *)CFDataGetMutableBytePtr((CFMutableDataRef)e) : NULL;
}
CFTypeRef CGEventCreateKeyboardEvent(CFTypeRef source, uint16_t keycode, bool down) {
    CFMutableDataRef e = CFDataCreateMutable(NULL, sizeof(KeyEvent));
    KeyEvent k = {.keycode = keycode, .down = down};
    CFDataAppendBytes(e, (const UInt8 *)&k, sizeof k);
    return e;
}
void CGEventKeyboardSetUnicodeString(CFTypeRef event, unsigned long length, const uint16_t *string) {
    KeyEvent *k = keyEvent(event);
    if (!k || !string) return;
    k->length = (uint8_t)MIN(length, 20ul);   // CGEvent's own limit is 20 UTF-16 units
    memcpy(k->chars, string, k->length * sizeof(UniChar));
}
static NSString *keyCharacters(const KeyEvent *k) {   // what a Mac keyboard layout gives the key, without its own string
    if (k->length) return [NSString stringWithCharacters:k->chars length:k->length];
    unichar c;
    switch (k->keycode) {
        case 36: c = '\r'; break; case 48: c = '\t'; break; case 49: c = ' '; break; case 51: c = 0x7f; break; case 53: c = 0x1b; break;
        case 123: c = 0xF702; break; case 124: c = 0xF703; break; case 125: c = 0xF701; break; case 126: c = 0xF700; break;   // arrows
        default: return @"";   // ponytail: letter keys without a string send no text; map them when something posts one
    }
    return [NSString stringWithCharacters:&c length:1];
}
void CGEventPost(uint32_t tap, CFTypeRef event) {
    static void (*post)(unsigned short, NSString *, BOOL);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ post = (void (*)(unsigned short, NSString *, BOOL))dlsym(RTLD_DEFAULT, "ShackAppKitPostKey"); });
    KeyEvent *k = keyEvent(event);
    if (k && post) post(k->keycode, keyCharacters(k), k->down);
}
void CGEventSourceSetLocalEventsSuppressionInterval(CFTypeRef source, double seconds) {}
uint32_t CGDisplayUnitNumber(CGDirectDisplayID display) { return 0; }
boolean_t CGDisplayIsAsleep(CGDirectDisplayID display) { return 0; }
uint32_t CGDisplayGammaTableCapacity(CGDirectDisplayID display) { return 0; }   // ponytail: no gamma ramps
// HIServices, through the ApplicationServices umbrella (Godot 3). The host is already a foreground app.
int32_t TransformProcessType(const void *psn, uint32_t transformState) { return 0; }
Boolean UAZoomEnabled(void) { return false; }   // Universal Access zoom (Factorio)
CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef mode) { return CFRetain(CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB")); }   // IO32BitDirectPixels
// Copy rule: the caller releases the device.
void *CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) { return (void *)CFBridgingRetain(MTLCreateSystemDefaultDevice()); }

// SDL2's display code (Hades II): one online display, capture and gamma are no-ops on a phone.
CGError CGGetOnlineDisplayList(uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *count) { return CGGetActiveDisplayList(maxDisplays, displays, count); }
CGError CGGetDisplaysWithRect(CGRect rect, uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *count) {   // Steam's UI
    uint32_t n = CGRectIntersectsRect(rect, CGDisplayBounds(1)) ? 1 : 0;
    if (displays && maxDisplays && n) displays[0] = 1;
    if (count) *count = displays ? (n < maxDisplays ? n : maxDisplays) : n;
    return kCGErrorSuccess;
}
boolean_t CGDisplayIsMain(CGDirectDisplayID display) { return display == 1; }
CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID display) { return 0; }   // kCGNullDirectDisplay: not mirrored
boolean_t CGDisplayIsInMirrorSet(CGDirectDisplayID display) { return 0; }   // Cyberpunk 2077
CGError CGCaptureAllDisplays(void) { return kCGErrorSuccess; }
CGError CGReleaseAllDisplays(void) { return kCGErrorSuccess; }
CGError CGDisplayCapture(CGDirectDisplayID display) { return kCGErrorSuccess; }
CGError CGDisplayRelease(CGDirectDisplayID display) { return kCGErrorSuccess; }
int32_t CGShieldingWindowLevel(void) { return 2147483630; }   // macOS value (kCGMaximumWindowLevel - 1 region)
CGError CGDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint point) { return kCGErrorSuccess; }
uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode) { return 0x3; }   // kDisplayModeValidFlag | kDisplayModeSafeFlag
const CFStringRef kCGDisplayShowDuplicateLowResolutionModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");
// Gamma: report and accept an identity ramp. ponytail: a game's brightness slider that uses gamma tables does nothing.
CGError CGGetDisplayTransferByTable(CGDirectDisplayID display, uint32_t capacity, float *red, float *green, float *blue, uint32_t *sampleCount) {
    uint32_t n = capacity < 256 ? capacity : 256;
    for (uint32_t i = 0; i < n; i++) { float v = n > 1 ? (float)i / (n - 1) : 0; if (red) red[i] = v; if (green) green[i] = v; if (blue) blue[i] = v; }
    if (sampleCount) *sampleCount = n;
    return kCGErrorSuccess;
}
CGError CGSetDisplayTransferByTable(CGDirectDisplayID display, uint32_t size, const float *red, const float *green, const float *blue) { return kCGErrorSuccess; }

// Screen capture (Godot 4's screen_get_image). ponytail: permission is never granted, so there is nothing to capture;
// the window list is empty (not NULL: callers CFRelease it) and the image is NULL, as macOS answers without access.
bool CGPreflightScreenCaptureAccess(void) { return false; }
bool CGRequestScreenCaptureAccess(void) { return false; }
CFArrayRef CGWindowListCreate(uint32_t option, uint32_t relativeToWindow) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
// Steam's UI lists the windows on screen after sign-in and counts the answer without a NULL check.
CFArrayRef CGWindowListCopyWindowInfo(uint32_t option, uint32_t relativeToWindow) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
CFArrayRef CGWindowListCreateDescriptionFromArray(CFArrayRef windows) { return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); }
CGImageRef CGWindowListCreateImageFromArray(CGRect bounds, CFArrayRef windows, uint32_t options) { return NULL; }

// macOS's standard window levels by key, CGWindowLevel.h order (SDL asks for the main-menu level for fullscreen).
int32_t CGWindowLevelForKey(int32_t key) {
    enum { base = INT32_MIN, min = base + 5, max = INT32_MAX - 16 };
    static const int32_t level[] = { base, min, min + 20, -20, 0, 3, 3, 20, 24, 25, 8, 101, 500, 1000, max, 102, 200, 19,
                                     min + 40, max - 1, 1500 };
    return key >= 0 && key < (int32_t)(sizeof level / sizeof *level) ? level[key] : 0;
}
