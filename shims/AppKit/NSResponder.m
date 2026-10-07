#import "ShackAppKit.h"
#import "ShackTextInput.h"
#import <objc/message.h>
@implementation NSResponder
SHACK_SAFETY_NET
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }   // AppKit's defaults: makeFirstResponder: asks both
- (BOOL)resignFirstResponder { return YES; }
#define FWD(sel) - (void)sel:(NSEvent *)e { [self.nextResponder sel:e]; }
FWD(mouseDown) FWD(mouseUp) FWD(mouseDragged) FWD(mouseMoved) FWD(rightMouseDown) FWD(rightMouseUp) FWD(scrollWheel)
FWD(keyDown) FWD(keyUp) FWD(flagsChanged)
// AppKit turns key events into text here for NSTextInputClient views: Unity's player view calls this from keyDown:,
// so without it no text field in a Unity game receives a single character (hardware or on-screen keyboard).
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events { ShackInterpretKeyEvents(self, events); }
- (void)doCommandBySelector:(SEL)s {
    if ([self respondsToSelector:s]) ((void (*)(id, SEL, id))objc_msgSend)(self, s, nil);
    else [self.nextResponder doCommandBySelector:s];
}
@end
