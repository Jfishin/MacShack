// Layer autoresizing on iOS (shims/AppKit/ShackLayout.m), the way Chromium's DisplayCALayerTree builds its tree:
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -framework UIKit -framework CoreGraphics -framework QuartzCore \
//     shims/AppKit/ShackLayout.m host/probe/test_layer_resize.m -o /tmp/t && xcrun simctl spawn booted /tmp/t
// Expect "layer resize ok" (iOS itself leaves the flipped layer 0x0).
#import <UIKit/UIKit.h>
#import <objc/message.h>
void ShackResizeSublayers(CALayer *l, CGSize old);

int main(void) {
    @autoreleasepool {
        CALayer *root = [CALayer layer], *flipped = [CALayer layer], *surface = [CALayer layer];
        flipped.geometryFlipped = YES; flipped.anchorPoint = CGPointZero;
        ((void (*)(id, SEL, unsigned))objc_msgSend)(flipped, @selector(setAutoresizingMask:), 2 | 16);   // width and height sizable
        [root addSublayer:flipped];
        surface.anchorPoint = CGPointZero; surface.bounds = CGRectMake(0, 0, 700, 440);
        [flipped addSublayer:surface];
        CGSize old = root.bounds.size;
        root.frame = CGRectMake(0, 0, 700, 440);
        ShackResizeSublayers(root, old);
        CGRect inRoot = [root convertRect:surface.bounds fromLayer:surface];
        BOOL ok = CGRectEqualToRect(flipped.frame, root.bounds) && CGRectEqualToRect(inRoot, root.bounds);
        printf("%s: flipped %s, surface in root %s\n", ok ? "layer resize ok" : "FAIL", NSStringFromCGRect(flipped.frame).UTF8String, NSStringFromCGRect(inRoot).UTF8String);
        return !ok;
    }
}
