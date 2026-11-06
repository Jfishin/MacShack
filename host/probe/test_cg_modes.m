// Display mode switches (shims/CG/ShackCG.m): a 1x mode sizes non-Retina GL surfaces, as a Mac's display switching to
// it does; the HiDPI desktop mode puts them back at 1x. Titan Souls' SDL 2.0.3 switches to the resolution its menu picks.
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -framework UIKit -framework Metal \
//     -framework CoreGraphics -framework QuartzCore shims/CG/ShackCG.m host/probe/test_cg_modes.m -o /tmp/t && xcrun simctl spawn booted /tmp/t
// Expect "cg modes ok".
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct CGDisplayMode *CGDisplayModeRef;
CFArrayRef CGDisplayCopyAllDisplayModes(uint32_t display, CFDictionaryRef options);
int32_t CGDisplaySetDisplayMode(uint32_t display, CGDisplayModeRef mode, CFDictionaryRef options);
size_t CGDisplayModeGetWidth(CGDisplayModeRef mode);
void ShackAppKitPostKey(unsigned short keyCode, NSString *characters, BOOL down) {}   // ShackCG.m's key path; unused here

// The AppKit shim's NSScreen, as ShackCG.m sees it: a 17 Pro Max at Full Retina.
@interface NSScreen : NSObject @property CGFloat glScale; @end
@implementation NSScreen
+ (NSScreen *)mainScreen { static NSScreen *s; if (!s) s = [NSScreen new]; return s; }
- (CGRect)frame { return CGRectMake(0, 0, 956, 440); }
- (CGFloat)backingScaleFactor { return 3; }
- (void)shack_setGLScale:(CGFloat)scale { self.glScale = scale; }
@end

static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s (gl scale %g)\n", what, NSScreen.mainScreen.glScale); exit(1); } }

int main(void) {
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(1, NULL));   // HiDPI 956x440, then 1x 2868x1320, 2150x990, ...
    Check(modes.count == 5 && CGDisplayModeGetWidth((__bridge CGDisplayModeRef)modes[1]) == 2868, "mode list");
    CGDisplaySetDisplayMode(1, (__bridge CGDisplayModeRef)modes[1], NULL);
    Check(NSScreen.mainScreen.glScale == 3, "2868x1320: 3x");
    CGDisplaySetDisplayMode(1, (__bridge CGDisplayModeRef)modes[2], NULL);
    Check(fabs(NSScreen.mainScreen.glScale * 956 - 2150) < 0.5, "2150x990: 2150 pixels across");
    CGDisplaySetDisplayMode(1, (__bridge CGDisplayModeRef)modes[0], NULL);
    Check(NSScreen.mainScreen.glScale == 1, "the HiDPI desktop mode: 1x");
    CGDisplaySetDisplayMode(1, NULL, NULL);
    Check(NSScreen.mainScreen.glScale == 1, "no mode: unchanged");
    puts("cg modes ok");
}
