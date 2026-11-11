#import "ShackHostView.h"
#import "ShackKeyMap.h"
#import "ShackTextInput.h"
#import "../ShackDisplay.h"

@interface ShackHostView ()
- (void)typeCharacters:(NSString *)s;
@end

// The on-screen keyboard's target. The iOS keyboard shows while it is first responder; each character typed (and
// delete) becomes a keyDown/keyUp pair, exactly as from a hardware keyboard, so games need nothing special.
@interface ShackKeyboardField : UIView <UIKeyInput>
@property (nonatomic, weak) ShackHostView *host;
@property (nonatomic) UITextAutocorrectionType autocorrectionType;
@property (nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property (nonatomic) UITextSpellCheckingType spellCheckingType;
@property (nonatomic) UIKeyboardAppearance keyboardAppearance;
@property (nonatomic) UIReturnKeyType returnKeyType;
@end
@implementation ShackKeyboardField
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _autocorrectionType = UITextAutocorrectionTypeNo; _autocapitalizationType = UITextAutocapitalizationTypeNone;
        _spellCheckingType = UITextSpellCheckingTypeNo; _keyboardAppearance = UIKeyboardAppearanceDark; _returnKeyType = UIReturnKeyDone;
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }   // so delete always reaches the game, which owns the real text
- (void)insertText:(NSString *)text {
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *c, NSRange r, NSRange er, BOOL *stop) {
        [self.host typeCharacters:[c isEqualToString:@"\n"] ? @"\r" : c];   // the Return key, as a Mac sends it
    }];
}
- (void)deleteBackward { [self.host typeCharacters:@"\x7f"]; }
@end

// A host's taker of fingers as touches (the Steam client's browsers, host ShackSteamTouch.m): asked first with the view
// under a starting finger and the finger's window point; YES keeps that finger off the mouse until it ends.
static BOOL (*gDirectTouch)(id view, int phase, CGPoint p);
void ShackAppKitSetDirectTouch(BOOL (*fn)(id, int, CGPoint)) { gDirectTouch = fn; }
// The same for a pointer's scroll: the view under the pointer, its window point, and the scroll in points as the content
// follows the fingers (UIKit's axes). YES: taken, no scroll wheel event.
static BOOL (*gDirectScroll)(id view, CGPoint p, CGPoint delta);
void ShackAppKitSetDirectScroll(BOOL (*fn)(id, CGPoint, CGPoint)) { gDirectScroll = fn; }

@implementation ShackHostView {
    UIView *_guestCanvas;
    CGSize _virtualSize;
    BOOL _virtualTouchActive;
    NSView *_directView;   // the view whose taker has the current finger
    UIPanGestureRecognizer *_trackpad;   // two-finger scrolls; a mouse wheel's are another recognizer, without momentum
    CGPoint _scrolled, _velocity, _coastAt;   // the scroll so far; the coast after the fingers lift, and where
    CADisplayLink *_coast;
    NSView *_panView;   // a trackpad scroll that is a finger to a touch taker
    CGPoint _panAnchor; double _panFar;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = NO; self.backgroundColor = UIColor.blackColor;
        // An iPad's pointer (trackpad, mouse), as a Mac's: hover moves the mouse, scrolls are the scroll wheel and a
        // trackpad's coast on after the fingers lift (over Steam: a finger, or its browser's wheel; scroll:). Clicks are
        // pointer touches.
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)]];
        for (NSNumber *type in @[@(UIScrollTypeMaskContinuous), @(UIScrollTypeMaskDiscrete)]) {
            UIPanGestureRecognizer *scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scroll:)];
            scroll.allowedScrollTypesMask = type.integerValue; scroll.allowedTouchTypes = @[];   // scrolls only, never a touch
            [self addGestureRecognizer:scroll];
            if (type.integerValue == UIScrollTypeMaskContinuous) _trackpad = scroll;
        }
        if (ShackVirtualDisplaySize(&_virtualSize)) {
            // UIKit owns this host's physical size. Only the guest canvas is transformed;
            // NSView frames and engine backing buffers keep the virtual desktop dimensions.
            _guestCanvas = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, _virtualSize}];
            _guestCanvas.clipsToBounds = YES;
            [self addSubview:_guestCanvas];
        }
    }
    return self;
}
- (void)shack_setGuestView:(UIView *)view {
    if (!_guestCanvas) { [self addSubview:view]; return; }
    for (UIView *old in _guestCanvas.subviews) if (old != view) [old removeFromSuperview];
    [_guestCanvas addSubview:view];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_guestCanvas) return;
    CGRect fitted = ShackDisplayCanvasRect(_virtualSize, self.bounds);
    if (fitted.size.width <= 0) return;
    CGFloat scale = fitted.size.width / _virtualSize.width;
    _guestCanvas.bounds = (CGRect){CGPointZero, _virtualSize};
    _guestCanvas.transform = CGAffineTransformMakeScale(scale, scale);
    _guestCanvas.center = CGPointMake(CGRectGetMidX(fitted), CGRectGetMidY(fitted));
}

- (NSPoint)windowPointAt:(CGPoint)p {
    if (_guestCanvas) p = ShackDisplayCanvasPoint(p, _virtualSize, self.bounds);
    return NSMakePoint(p.x, (_guestCanvas ? _virtualSize.height : self.bounds.size.height) - p.y);   // AppKit: origin bottom-left
}
- (NSPoint)windowPoint:(UITouch *)touch { return [self windowPointAt:[touch locationInView:self]]; }
- (NSEvent *)mouseEvent:(NSEventType)t at:(CGPoint)p time:(NSTimeInterval)time {
    NSEvent *e = [NSEvent new]; e.type = t; e.window = self.nsWindow; e.windowNumber = self.nsWindow.windowNumber; e.timestamp = time;
    e.modifierFlags = NSEvent.modifierFlags; e.buttonNumber = 0; e.clickCount = 0;
    e.locationInWindow = [self windowPointAt:p];
    [NSEvent shack_setMouseLocation:e.locationInWindow];
    return e;
}
- (NSEvent *)mouseEvent:(NSEventType)t touch:(UITouch *)touch {
    NSEvent *e = [self mouseEvent:t at:[touch locationInView:self] time:touch.timestamp];
    e.clickCount = touch.tapCount;
    [NSEvent shack_setPressedMouseButtons:t == NSEventTypeLeftMouseUp ? 0 : 1];
    return e;
}
- (void)hover:(UIHoverGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan && g.state != UIGestureRecognizerStateChanged) return;
    [NSApp sendEvent:[self mouseEvent:NSEventTypeMouseMoved at:[g locationInView:self] time:NSProcessInfo.processInfo.systemUptime]];
}
// A scroll of d points (content following the fingers) at p: to a taker (Steam's browsers), else a Mac scroll wheel
// event. ponytail: a line per 10 points, as a wheel without precise deltas; precise trackpad deltas when a game needs them.
- (void)scrollBy:(CGPoint)d at:(CGPoint)p {
    NSPoint w = [self windowPointAt:p];
    NSView *hit = gDirectScroll ? [self.nsWindow.contentView hitTest:w] : nil;
    if (hit && gDirectScroll(hit, w, d)) return;
    NSEvent *e = [self mouseEvent:NSEventTypeScrollWheel at:p time:NSProcessInfo.processInfo.systemUptime];
    e.deltaX = e.scrollingDeltaX = d.x / 10; e.deltaY = e.scrollingDeltaY = d.y / 10;
    [NSApp sendEvent:e];
}
// A trackpad's two fingers over a touch taker (Steam's browsers) are a finger there, from the pointer: Chromium follows
// it 1:1, keeps to the axis it starts on (a wheel's sideways drift turned Big Picture's shelves) and coasts on itself.
// A scroll shorter than a tap's slop is cancelled, so it never clicks.
- (void)scroll:(UIPanGestureRecognizer *)g {
    CGPoint at = [g locationInView:self], t = [g translationInView:self];
    UIGestureRecognizerState s = g.state;
    if (s == UIGestureRecognizerStateBegan) {
        [self stopCoasting]; _scrolled = CGPointZero; _panAnchor = at; _panFar = 0;
        NSPoint w = [self windowPointAt:at];
        NSView *hit = g == _trackpad && gDirectTouch && !_directView ? [self.nsWindow.contentView hitTest:w] : nil;
        if (hit && gDirectTouch(hit, 0, w)) _panView = hit;
    }
    if (_panView) {
        NSPoint w = [self windowPointAt:CGPointMake(_panAnchor.x + t.x, _panAnchor.y + t.y)];
        _panFar = fmax(_panFar, hypot(t.x, t.y));
        if (s == UIGestureRecognizerStateChanged) gDirectTouch(_panView, 1, w);
        else if (s != UIGestureRecognizerStateBegan) { gDirectTouch(_panView, s == UIGestureRecognizerStateEnded && _panFar >= 20 ? 2 : 3, w); _panView = nil; }
        return;
    }
    if (s == UIGestureRecognizerStateChanged) {
        [self scrollBy:CGPointMake(t.x - _scrolled.x, t.y - _scrolled.y) at:at];
        _scrolled = t;
    }
    if (s == UIGestureRecognizerStateEnded && g == _trackpad) {   // a trackpad coasts on, as on a Mac
        _velocity = [g velocityInView:self]; _coastAt = at;
        _coast = [CADisplayLink displayLinkWithTarget:self selector:@selector(coast:)];
        [_coast addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
// UIScrollView's normal deceleration (0.998 per ms); it stops below 20 points a second, or at the next scroll or touch.
- (void)coast:(CADisplayLink *)link {
    double dt = link.targetTimestamp - link.timestamp, keep = pow(0.998, dt * 1000);
    _velocity = CGPointMake(_velocity.x * keep, _velocity.y * keep);
    if (hypot(_velocity.x, _velocity.y) < 20) { [self stopCoasting]; return; }
    [self scrollBy:CGPointMake(_velocity.x * dt, _velocity.y * dt) at:_coastAt];
}
- (void)stopCoasting { [_coast invalidate]; _coast = nil; }
- (BOOL)keyboardShown {
    for (UIView *v in self.subviews) if ([v isKindOfClass:ShackKeyboardField.class] && v.isFirstResponder) return YES;
    return NO;
}
// A touch makes the game view first responder (hardware keys, pads), except while the on-screen keyboard is up: tapping
// the game's text field must not dismiss it.
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev {
    if (_guestCanvas) {
        if (!CGRectContainsPoint(ShackDisplayCanvasRect(_virtualSize, self.bounds), [ts.anyObject locationInView:self])) return;
        _virtualTouchActive = YES;
    }
    if (!self.keyboardShown) [self becomeFirstResponder];
    [self stopCoasting];   // a touch or click catches a coasting scroll, as on a Mac
    if (_panView) { gDirectTouch(_panView, 3, [self windowPointAt:_panAnchor]); _panView = nil; }   // one finger at a time
    if (gDirectTouch && ts.anyObject.type == UITouchTypeDirect) {   // a finger; the iPad pointer stays a mouse, as on a Mac
        NSPoint p = [self windowPoint:ts.anyObject];
        NSView *hit = [self.nsWindow.contentView hitTest:p];
        if (hit && gDirectTouch(hit, 0, p)) { _directView = hit; return; }
    }
    [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseDown touch:ts.anyObject]];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev {
    if (_directView) gDirectTouch(_directView, 1, [self windowPoint:ts.anyObject]);
    else if (!_guestCanvas || _virtualTouchActive) [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseDragged touch:ts.anyObject]];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev { [self touchesEnded:ts phase:2]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev { [self touchesEnded:ts phase:3]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts phase:(int)phase {
    if (_directView) gDirectTouch(_directView, phase, [self windowPoint:ts.anyObject]);
    else if (!_guestCanvas || _virtualTouchActive) [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseUp touch:ts.anyObject]];
    _directView = nil;
    _virtualTouchActive = NO;
}

// Mac keycodes 54-63 are modifiers: AppKit reports them as flagsChanged with the updated modifier state, never keyDown/keyUp.
static NSEventModifierFlags ModifierFlagForKeyCode(unsigned short k) {
    switch (k) {
        case 54: case 55: return NSEventModifierFlagCommand; case 56: case 60: return NSEventModifierFlagShift;
        case 57: return NSEventModifierFlagCapsLock; case 58: case 61: return NSEventModifierFlagOption;
        case 59: case 62: return NSEventModifierFlagControl; case 63: return NSEventModifierFlagFunction; default: return 0;
    }
}
- (void)press:(UIPress *)p down:(BOOL)down {
    unsigned short k = ShackMacKeyCode(p.key.keyCode);
    NSEventModifierFlags flag = ModifierFlagForKeyCode(k), m = NSEvent.modifierFlags;
    if (flag) {   // ponytail: left/right of the same modifier share a bit; releasing one clears it
        if (flag == NSEventModifierFlagCapsLock) { if (down) m ^= flag; } else m = down ? (m | flag) : (m & ~flag);
        [NSEvent shack_setModifierFlags:m];
    }
    NSEvent *e = [NSEvent new]; e.type = flag ? NSEventTypeFlagsChanged : down ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    e.window = self.nsWindow; e.windowNumber = self.nsWindow.windowNumber; e.timestamp = p.timestamp; e.keyCode = k; e.modifierFlags = m;
    if (!flag) { e.characters = p.key.characters; e.charactersIgnoringModifiers = p.key.charactersIgnoringModifiers; e.isARepeat = NO; }
    e.locationInWindow = NSEvent.mouseLocation;
    [NSApp sendEvent:e];
}
- (void)typeCharacters:(NSString *)s {
    unsigned short k = ShackKeyCodeForCharacter([s characterAtIndex:0]);
    for (int down = 1; down >= 0; down--) {
        NSEvent *e = [NSEvent new]; e.type = down ? NSEventTypeKeyDown : NSEventTypeKeyUp;
        e.window = self.nsWindow; e.windowNumber = self.nsWindow.windowNumber; e.timestamp = NSProcessInfo.processInfo.systemUptime;
        e.keyCode = k == 0xFFFF ? 0 : k; e.modifierFlags = NSEvent.modifierFlags;
        e.characters = s; e.charactersIgnoringModifiers = s.lowercaseString; e.isARepeat = NO;
        e.locationInWindow = NSEvent.mouseLocation;
        [NSApp sendEvent:e];
    }
}
- (void)toggleKeyboard {
    ShackKeyboardField *field = nil;
    for (UIView *v in self.subviews) if ([v isKindOfClass:ShackKeyboardField.class]) field = (ShackKeyboardField *)v;
    if (!field) { field = [[ShackKeyboardField alloc] initWithFrame:CGRectMake(0, 0, 1, 1)]; field.host = self; field.alpha = 0.01; [self addSubview:field]; }
    if (field.isFirstResponder) { [field resignFirstResponder]; [self becomeFirstResponder]; }   // hardware keys and pads back to the game
    else {
        [self.window makeKeyWindow];   // the island menu lives in MacShack's overlay window; the keyboard needs the game's key
        [field becomeFirstResponder];
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)ps withEvent:(UIPressesEvent *)ev { for (UIPress *p in ps) if (p.key) [self press:p down:YES]; else [super pressesBegan:[NSSet setWithObject:p] withEvent:ev]; }
- (void)pressesEnded:(NSSet<UIPress *> *)ps withEvent:(UIPressesEvent *)ev { for (UIPress *p in ps) if (p.key) [self press:p down:NO]; else [super pressesEnded:[NSSet setWithObject:p] withEvent:ev]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)ps withEvent:(UIPressesEvent *)ev { [self pressesEnded:ps withEvent:ev]; }   // no stuck keys on backgrounding
@end
