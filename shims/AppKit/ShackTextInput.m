#import "ShackTextInput.h"
#import <objc/message.h>

// AppKit's standard key bindings for the keys a text field reacts to (StandardKeyBinding.dict); NULL = not a command.
static SEL CommandForCharacter(unichar c) {
    switch (c) {
        case '\r': case '\n': case 0x03: return @selector(insertNewline:);
        case '\t': return @selector(insertTab:);
        case 0x19: return @selector(insertBacktab:);
        case 0x7f: case 0x08: return @selector(deleteBackward:);
        case 0xF728: return @selector(deleteForward:);        // NSDeleteFunctionKey
        case 0x1b: return @selector(cancelOperation:);
        case 0xF700: return @selector(moveUp:);                // NSUpArrowFunctionKey
        case 0xF701: return @selector(moveDown:);
        case 0xF702: return @selector(moveLeft:);
        case 0xF703: return @selector(moveRight:);
        case 0xF729: return @selector(scrollToBeginningOfDocument:);   // Home
        case 0xF72B: return @selector(scrollToEndOfDocument:);         // End
        case 0xF72C: return @selector(scrollPageUp:);
        case 0xF72D: return @selector(scrollPageDown:);
        default: return NULL;
    }
}

void ShackInterpretKeyEvents(id responder, NSArray *events) {
    for (id e in events) {
        NSString *chars = ((NSString *(*)(id, SEL))objc_msgSend)(e, @selector(characters));
        NSUInteger flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(e, @selector(modifierFlags));
        if (!chars.length || (flags & (1 << 20))) continue;   // NSEventModifierFlagCommand: a key equivalent, not text
        unichar c = [chars characterAtIndex:0];
        SEL command = CommandForCharacter(c);
        if (command) {
            if ([responder respondsToSelector:@selector(doCommandBySelector:)])
                ((void (*)(id, SEL, SEL))objc_msgSend)(responder, @selector(doCommandBySelector:), command);
            else if ([responder respondsToSelector:command]) ((void (*)(id, SEL, id))objc_msgSend)(responder, command, nil);
            continue;
        }
        if (c < 0x20 || (c >= 0xF700 && c <= 0xF8FF)) continue;   // other control and function keys: no text
        if ([responder respondsToSelector:@selector(insertText:replacementRange:)])
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(responder, @selector(insertText:replacementRange:), chars, NSMakeRange(NSNotFound, 0));
        else if ([responder respondsToSelector:@selector(insertText:)])
            ((void (*)(id, SEL, id))objc_msgSend)(responder, @selector(insertText:), chars);
    }
}

unsigned short ShackKeyCodeForCharacter(unichar c) {
    static const char *keys = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\0lj'k;\\,/nm.\0 `";   // index = Mac key code (US layout)
    if (c == '\r' || c == '\n') return 36;
    if (c == '\t') return 48;
    if (c == 0x7f || c == 0x08) return 51;
    if (c == 0x1b) return 53;
    if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (c > 0x7f || !c) return 0xFFFF;
    for (unsigned short k = 0; k <= 50; k++) if (keys[k] == c) return k;
    return 0xFFFF;
}
