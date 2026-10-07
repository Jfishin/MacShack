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

@implementation ShackHostView {
    UIView *_guestCanvas;
    CGSize _virtualSize;
    BOOL _virtualTouchActive;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = NO; self.backgroundColor = UIColor.blackColor;
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

- (NSEvent *)mouseEvent:(NSEventType)t touch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    if (_guestCanvas) p = ShackDisplayCanvasPoint(p, _virtualSize, self.bounds);
    NSEvent *e = [NSEvent new]; e.type = t; e.window = self.nsWindow; e.windowNumber = self.nsWindow.windowNumber; e.timestamp = touch.timestamp;
    e.modifierFlags = NSEvent.modifierFlags; e.buttonNumber = 0; e.clickCount = touch.tapCount;
    [NSEvent shack_setPressedMouseButtons:t == NSEventTypeLeftMouseUp ? 0 : 1];
    e.locationInWindow = NSMakePoint(p.x, (_guestCanvas ? _virtualSize.height : self.bounds.size.height) - p.y);   // AppKit: origin bottom-left
    [NSEvent shack_setMouseLocation:e.locationInWindow];
    return e;
}
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
    [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseDown touch:ts.anyObject]];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev { if (!_guestCanvas || _virtualTouchActive) [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseDragged touch:ts.anyObject]]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev {
    if (!_guestCanvas || _virtualTouchActive) [NSApp sendEvent:[self mouseEvent:NSEventTypeLeftMouseUp touch:ts.anyObject]];
    _virtualTouchActive = NO;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)ev { [self touchesEnded:ts withEvent:ev]; }

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
