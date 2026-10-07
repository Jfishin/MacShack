#import "ShackAppKit.h"
#import <objc/message.h>
@implementation NSView { UIView *_ui; CALayer *_layer; NSMutableArray *_subviews; NSMutableArray *_tracking; BOOL _bestGL, _needsDisplay; CGSize _reshaped; NSUInteger _autoresizing; }
// ponytail: stored, never fire (see NSTrackingArea); touches reach the view as NSEvents.
- (void)addTrackingArea:(id)area { if (!area) return; if (!_tracking) _tracking = [NSMutableArray array]; [_tracking addObject:area]; }
- (void)removeTrackingArea:(id)area { [_tracking removeObject:area]; }
- (NSArray *)trackingAreas { return _tracking ?: @[]; }
// As in AppKit, a GL surface is Retina only when asked (GLFW asks; Godot 3 without allow_hidpi does not, and draws
// its window size in points: at 3x its picture filled a third of the screen). Core Animation scales a 1x surface up.
- (void)setWantsBestResolutionOpenGLSurface:(BOOL)f { _bestGL = f; if (_ui && _layer) ShackMainSync(^{ [self attachLayer]; }); }
- (BOOL)wantsBestResolutionOpenGLSurface { return _bestGL; }
- (void)updateTrackingAreas {}   // GLFW's override calls super; a forwarded super-send traps in NSInvocation
@synthesize frame = _frame, bounds = _bounds;
- (instancetype)initWithFrame:(NSRect)r { if ((self = [super init])) { _frame = r; _bounds = (NSRect){NSZeroPoint, r.size}; _subviews = [NSMutableArray array]; } return self; }
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (UIView *)uiView {
    if (!_ui) ShackMainSync(^{ if (self->_ui) return; self->_ui = [[UIView alloc] initWithFrame:[self uiFrame]]; self->_ui.hidden = self->_hidden; if (self->_layer) [self attachLayer]; });
    return _ui;
}
// AppKit frames are bottom-left origin inside the superview; UIKit's are top-left.
// ponytail: the content view has no superview here, so its frame is identity.
- (CGRect)uiFrame { NSRect r = _frame; if (_superview) r.origin.y = _superview.frame.size.height - r.origin.y - r.size.height; return r; }
- (void)attachLayer {   // main thread. ponytail: the game's layer becomes a sublayer; enough for CAMetalLayer rendering
    CGSize old = _layer.bounds.size;
    _layer.frame = _ui.bounds;
    ShackResizeSublayers(_layer, old);
    _layer.contentsScale = [_layer isKindOfClass:NSClassFromString(@"CAEAGLLayer")] && !_bestGL ? 1 : NSScreen.mainScreen.backingScaleFactor;
    if (_layer.superlayer != _ui.layer) [_ui.layer addSublayer:_layer];
    NSLog(@"[ShackAppKit] attachLayer %@ bounds %@ scale %.1f", NSStringFromClass(_layer.class), NSStringFromCGRect(_layer.bounds), _layer.contentsScale);
}
- (void)setLayer:(CALayer *)l {
    if (l == _layer) return;
    CALayer *old = _layer; _layer = l;
    if (_ui) ShackMainSync(^{ if (old.superlayer == self->_ui.layer) [old removeFromSuperlayer]; if (l) [self attachLayer]; });
}
// UE4's FMetalView overrides makeBackingLayer to return a CAMetalLayer and reads self.layer expecting that object.
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setWantsLayer:(BOOL)f { _wantsLayer = f; if (f && !_layer) self.layer = [self makeBackingLayer]; }
- (CALayer *)layer { if (!_layer && _wantsLayer) self.layer = [self makeBackingLayer]; return _layer; }
// As in AppKit, setFrame: goes through setFrameOrigin: and setFrameSize:, which a subclass may override (CoronaView forwards
// setFrameSize: to its GLView); those, called directly, end in the one place the frame is applied.
- (void)setFrame:(NSRect)r {
    if (!CGPointEqualToPoint(_frame.origin, r.origin)) [self setFrameOrigin:r.origin];
    if (!CGSizeEqualToSize(_frame.size, r.size)) [self setFrameSize:r.size];
}
- (void)shack_applyFrame:(NSRect)r {
    NSSize old = _frame.size;
    _frame = r; _bounds = (NSRect){NSZeroPoint, r.size};
    [self shack_syncUIFrame];
    if (!CGSizeEqualToSize(old, r.size)) {
        [self resizeSubviewsWithOldSize:old];
        // A subview's UIKit frame is measured from the top and so depends on this view's height, which a subclass may only
        // have changed after sizing the subview (CoronaView sizes its GL view, then calls super): place them again.
        for (NSView *v in [_subviews copy]) [v shack_syncUIFrame];
    }
}
- (void)shack_syncUIFrame { if (_ui) ShackMainSync(^{ self->_ui.frame = [self uiFrame]; if (self->_layer) [self attachLayer]; }); }
- (void)resizeSubviewsWithOldSize:(NSSize)old {
    NSSize now = _frame.size;
    for (NSView *v in [_subviews copy]) {
        NSUInteger m = v->_autoresizing;
        if (!m) continue;
        NSRect f = v.frame;
        f.origin.x = ShackResized(f.origin.x, f.size.width, old.width, now.width, 1, 2, 4, m, &f.size.width);
        f.origin.y = ShackResized(f.origin.y, f.size.height, old.height, now.height, 8, 16, 32, m, &f.size.height);
        if (!CGRectEqualToRect(f, v.frame)) v.frame = f;   // its own setFrame: resizes the next level
    }
}
- (NSUInteger)autoresizingMask { return _autoresizing; }
- (void)setAutoresizesSubviews:(BOOL)f {}
- (void)setFrameSize:(NSSize)s { [self shack_applyFrame:(NSRect){_frame.origin, s}]; }
- (void)setFrameOrigin:(NSPoint)p { [self shack_applyFrame:(NSRect){p, _frame.size}]; }
// The deepest visible subview under `p`, given in the superview's coordinates (the content view's are the window's).
- (NSView *)hitTest:(NSPoint)p {
    if (self.hidden || !CGRectContainsPoint(_frame, p)) return nil;
    NSPoint local = NSMakePoint(p.x - _frame.origin.x, p.y - _frame.origin.y);
    for (NSView *v in [_subviews reverseObjectEnumerator]) { NSView *h = [v hitTest:local]; if (h) return h; }
    return self;
}
- (void)setHidden:(BOOL)h { _hidden = h; if (_ui) ShackMainSync(^{ self->_ui.hidden = h; }); }
- (NSArray<NSView *> *)subviews { return [_subviews copy]; }
- (void)setSubviews:(NSArray<NSView *> *)views {   // Feral's view sets one and reads it back with objectAtIndex:0
    for (NSView *v in [_subviews copy]) [v removeFromSuperview];
    for (NSView *v in views) [self addSubview:v];
}
- (void)addSubview:(NSView *)v {
    [_subviews addObject:v]; v.superview = self; v.nextResponder = self;
    UIView *u = self.uiView, *c = v.uiView; ShackMainSync(^{ c.frame = [v uiFrame]; [u addSubview:c]; });
    [v shack_moveToWindow:self.window];
}
// AppKit's ordered insert: above or below a sibling (NSWindowAbove 1, NSWindowBelow -1), or all of them for nil.
// Chromium puts its RenderWidgetHostViewCocoa into its WebContentsViewCocoa this way; Steam Helper then looks it up.
- (void)addSubview:(NSView *)v positioned:(NSInteger)place relativeTo:(NSView *)other {
    NSUInteger at = other ? [_subviews indexOfObject:other] : NSNotFound;
    at = at == NSNotFound ? (place > 0 ? _subviews.count : 0) : at + (place > 0);
    [_subviews insertObject:v atIndex:at]; v.superview = self; v.nextResponder = self;
    UIView *u = self.uiView, *c = v.uiView; ShackMainSync(^{ c.frame = [v uiFrame]; [u insertSubview:c atIndex:(NSInteger)at]; });
    [v shack_moveToWindow:self.window];
}
// A view that gets a window (its own or an ancestor's) hears viewDidMoveToWindow, and is drawn: AppKit marks a view that
// enters a window as needing display.
- (void)viewWillMoveToWindow:(NSWindow *)w {}
- (void)viewDidMoveToWindow {}
- (void)shack_moveToWindow:(NSWindow *)w {
    if (self.window == w) return;
    [self viewWillMoveToWindow:w];
    self.window = w;
    for (NSView *s in [_subviews copy]) [s shack_moveToWindow:w];
    [self viewDidMoveToWindow];
    if (w) [self setNeedsDisplay:YES];
}
// Drawing: a view that implements drawRect: (a subclass; NSView itself draws nothing) is drawn on the app thread's run
// loop after setNeedsDisplay:. An NSOpenGLView first gets its context made current, which creates it and sends
// prepareOpenGL once, and reshape when its size changed (CoronaCards' GLView renders from drawRect:).
- (BOOL)needsDisplay { return _needsDisplay; }
- (void)setNeedsDisplay:(BOOL)f {
    if (!f || _needsDisplay || ![self respondsToSelector:@selector(drawRect:)]) return;
    _needsDisplay = YES;
    CFRunLoopRef loop = NSApp ? [NSApp shack_appLoop] : CFRunLoopGetCurrent();
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [self displayIfNeeded]; });
    CFRunLoopWakeUp(loop);
}
- (void)setNeedsDisplayInRect:(NSRect)r { [self setNeedsDisplay:YES]; }
- (void)displayIfNeeded {
    if (!_needsDisplay) return;
    _needsDisplay = NO;   // before drawing: drawRect: may already ask for the next frame
    if ([self respondsToSelector:@selector(openGLContext)]) {
        id ctx = [self performSelector:@selector(openGLContext)];
        [ctx performSelector:@selector(makeCurrentContext)];
        if (!CGSizeEqualToSize(_reshaped, self.bounds.size)) {
            _reshaped = self.bounds.size;
            if ([self respondsToSelector:@selector(reshape)]) [self performSelector:@selector(reshape)];
        }
    }
    ((void (*)(id, SEL, NSRect))objc_msgSend)(self, @selector(drawRect:), self.bounds);
}
- (void)display { _needsDisplay = YES; [self displayIfNeeded]; }
- (BOOL)inLiveResize { return NO; }
- (NSRect)visibleRect { return self.bounds; }   // ponytail: views fill the screen and nothing clips them (GameMaker asks)
- (void)lockFocus {} - (void)unlockFocus {}
- (NSInteger)addTrackingRect:(NSRect)r owner:(id)owner userData:(void *)data assumeInside:(BOOL)inside { static NSInteger tag; return ++tag; }
- (void)removeTrackingRect:(NSInteger)tag {}
- (void)removeFromSuperview {
    // As in AppKit, a removed view lives on until the autorelease pool drains: the superview's array may hold the last
    // reference, and Steam Helper moves CEF's browser view by removing it and adding it elsewhere without keeping it.
    CFAutorelease(CFBridgingRetain(self));
    if (_superview) [_superview->_subviews removeObjectIdenticalTo:self];   // no superview is legal (SDL2 does it); -> on nil faults
    _superview = nil; _window = nil;
    if (_ui) ShackMainSync(^{ [self->_ui removeFromSuperview]; });
}
- (void)setAutoresizingMask:(NSUInteger)m { _autoresizing = m; }
- (void)setAlphaValue:(CGFloat)a {}
- (void)registerForDraggedTypes:(NSArray *)t {}
- (id)inputContext { return nil; }   // ponytail: no IME; UE4 checks for nil
- (void)discardMarkedText {} - (void)unmarkText {}
- (BOOL)isOpaque { return NO; }
- (BOOL)isFlipped { return NO; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v { return p; }   // ponytail: single content view, identity is correct
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v { return p; }
- (NSRect)convertRect:(NSRect)r fromView:(NSView *)v { return r; }
- (NSRect)convertRect:(NSRect)r toView:(NSView *)v { return r; }
- (NSRect)convertRectToBacking:(NSRect)r { CGFloat s = NSScreen.mainScreen.backingScaleFactor; return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s); }
- (NSRect)convertRectFromBacking:(NSRect)r { CGFloat s = NSScreen.mainScreen.backingScaleFactor; return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s); }
- (NSSize)convertSizeToBacking:(NSSize)z { CGFloat s = NSScreen.mainScreen.backingScaleFactor; return CGSizeMake(z.width * s, z.height * s); }
- (BOOL)acceptsFirstResponder { return YES; }
@end
