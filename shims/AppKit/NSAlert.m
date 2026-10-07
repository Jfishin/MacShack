#import "ShackAppKit.h"
// ponytail: alerts are logged, not shown; runModal answers the first button.
@interface NSAlert : NSObject
+ (NSAlert *)alertWithMessageText:(NSString *)message defaultButton:(NSString *)def alternateButton:(NSString *)alt otherButton:(NSString *)other
        informativeTextWithFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(5,6);
@property (nonatomic, copy) NSString *messageText, *informativeText; @property (nonatomic) NSUInteger alertStyle;
@property (nonatomic, strong) NSView *accessoryView; @property (nonatomic, readonly) id window;
- (id)addButtonWithTitle:(NSString *)title; - (NSInteger)runModal;
@end
@implementation NSAlert { NSMutableArray<NSString *> *_buttons; }
SHACK_SAFETY_NET
+ (NSAlert *)alertWithMessageText:(NSString *)message defaultButton:(NSString *)def alternateButton:(NSString *)alt otherButton:(NSString *)other
        informativeTextWithFormat:(NSString *)format, ... {
    NSAlert *a = [self new]; a.messageText = message;
    va_list ap; va_start(ap, format); a.informativeText = [[NSString alloc] initWithFormat:format arguments:ap]; va_end(ap);
    [a addButtonWithTitle:def ?: @"OK"]; if (alt) [a addButtonWithTitle:alt]; if (other) [a addButtonWithTitle:other];
    return a;
}
- (instancetype)init { if ((self = [super init])) _buttons = [NSMutableArray array]; return self; }
- (id)addButtonWithTitle:(NSString *)title { [_buttons addObject:title]; return nil; }   // ponytail: no NSButton class
- (id)window { return nil; }
- (NSInteger)runModal {
    NSLog(@"[ShackAppKit] NSAlert: %@ — %@ [%@]", _messageText, _informativeText, [_buttons componentsJoinedByString:@", "]);
    return 1000;   // NSAlertFirstButtonReturn
}
@end
