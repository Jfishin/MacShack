// The pointer across the CG and Carbon shims (shims/CG/ShackCG.m, shims/Carbon/ShackLegacy.m): a warp moves it, and
// HIGetMousePosition reads it back in CG's global space (top-left origin, points), as on a Mac. Mouse-look code warps to
// the window's middle every frame and takes the difference (Batman: Arkham Asylum); a read that misses the warp spins
// the camera. NSEvent and NSScreen here stand in for libShackAppKit's.
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -framework UIKit -framework Metal \
//     -framework CoreGraphics -framework QuartzCore shims/CG/ShackCG.m shims/Carbon/ShackLegacy.m shims/Carbon/ShackCarbon.m \
//     host/probe/test_mouse_warp.m -o /tmp/t && xcrun simctl spawn booted /tmp/t
// Expect "mouse warp ok".
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

OSStatus HIGetMousePosition(uint32_t space, void *object, CGPoint *out);
CGError CGWarpMouseCursorPosition(CGPoint p);   // macOS CoreGraphics; iOS has no pointer

static CGPoint gMouse;   // NSEvent's, bottom-left origin
@interface NSEvent : NSObject @end
@implementation NSEvent
+ (CGPoint)mouseLocation { return gMouse; }
+ (void)shack_setMouseLocation:(CGPoint)p { gMouse = p; }
@end
@interface NSScreen : NSObject @end
@implementation NSScreen
+ (NSScreen *)mainScreen { static NSScreen *s; if (!s) s = [NSScreen new]; return s; }
- (CGRect)frame { return CGRectMake(0, 0, 956, 440); }
- (CGFloat)backingScaleFactor { return 3; }
@end

int main(void) { @autoreleasepool {
    CGPoint p = {0};
    assert(CGWarpMouseCursorPosition(CGPointMake(478, 220)) == kCGErrorSuccess);
    assert(HIGetMousePosition(1, NULL, &p) == 0 && p.x == 478 && p.y == 220);     // kHICoordSpaceScreenPixel
    assert(CGWarpMouseCursorPosition(CGPointMake(10, 30)) == kCGErrorSuccess);
    assert(gMouse.x == 10 && gMouse.y == 410);                                    // NSEvent: bottom-left origin
    assert(HIGetMousePosition(2, NULL, &p) == 0 && p.x == 10 && p.y == 30);       // kHICoordSpace72DPIGlobal
    gMouse = CGPointMake(100, 400);                                               // a touch moved the pointer
    assert(HIGetMousePosition(1, NULL, &p) == 0 && p.x == 100 && p.y == 40);
    puts("mouse warp ok");
}}
