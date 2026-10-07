// Springs and struts for views and layers (AppKit's autoresizingMask), shared by NSView and its layer.
// Simulator check: header of host/probe/test_layer_resize.m.
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// One axis of a frame after its parent changed from oldParent to newParent. Margin and size bits (views and layers
// alike): 1 min-X margin, 2 width, 4 max-X margin, 8 min-Y margin, 16 height, 32 max-Y margin.
CGFloat ShackResized(CGFloat pos, CGFloat len, CGFloat oldParent, CGFloat newParent, NSUInteger minMargin, NSUInteger size, NSUInteger maxMargin, NSUInteger mask, CGFloat *outLen) {
    CGFloat delta = newParent - oldParent;
    int flexible = ((mask & minMargin) ? 1 : 0) + ((mask & size) ? 1 : 0) + ((mask & maxMargin) ? 1 : 0);
    if (!flexible) { *outLen = len; return pos; }
    CGFloat share = delta / flexible;
    *outLen = (mask & size) ? len + share : len;
    return (mask & minMargin) ? pos + share : pos;
}

// iOS keeps a layer's autoresizingMask (Mac Catalyst API) but never applies it: a layer-backed view's sublayers follow
// its layer here, as on macOS. Chromium hangs each frame (an IOSurface layer) under a geometry-flipped layer only
// autoresizing sizes; left 0x0, the flip put Steam's page above the screen.
// ponytail: the Y margins are taken in the layer's own (top-down) space; a layer-hosting NSView's is bottom-up.
void ShackResizeSublayers(CALayer *l, CGSize old) {
    CGSize now = l.bounds.size;
    if (CGSizeEqualToSize(old, now)) return;
    for (CALayer *sub in l.sublayers) {
        NSUInteger m = [sub respondsToSelector:@selector(autoresizingMask)] ? ((unsigned (*)(id, SEL))objc_msgSend)(sub, @selector(autoresizingMask)) : 0;
        if (!m) continue;
        CGRect f = sub.frame; CGSize was = sub.bounds.size;
        f.origin.x = ShackResized(f.origin.x, f.size.width, old.width, now.width, 1, 2, 4, m, &f.size.width);
        f.origin.y = ShackResized(f.origin.y, f.size.height, old.height, now.height, 8, 16, 32, m, &f.size.height);
        sub.frame = f;
        ShackResizeSublayers(sub, was);
    }
}
