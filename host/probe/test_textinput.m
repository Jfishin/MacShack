// Mac check: clang -fobjc-arc shims/AppKit/ShackTextInput.m host/probe/test_textinput.m -framework Foundation -o /tmp/ti && /tmp/ti
#import <Foundation/Foundation.h>
#import "../../shims/AppKit/ShackTextInput.h"

@interface FakeEvent : NSObject
@property NSString *characters; @property NSUInteger modifierFlags;
@end
@implementation FakeEvent @end

@interface Field : NSObject
@property NSMutableArray<NSString *> *log;
@end
@implementation Field
- (instancetype)init { if ((self = [super init])) _log = [NSMutableArray array]; return self; }
- (void)insertText:(id)s replacementRange:(NSRange)r { [_log addObject:[NSString stringWithFormat:@"text:%@", s]]; }
- (void)doCommandBySelector:(SEL)s { [_log addObject:NSStringFromSelector(s)]; }
@end

static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }
static FakeEvent *Key(NSString *c) { FakeEvent *e = [FakeEvent new]; e.characters = c; return e; }

int main(void) {
    @autoreleasepool {
        Field *f = [Field new];
        ShackInterpretKeyEvents(f, @[Key(@"V"), Key(@"i"), Key(@"\x7f"), Key(@"\r"), Key(@"\t"), Key(@"\x1b"), Key(@""), Key(@"")]);
        NSArray *want = @[@"text:V", @"text:i", @"deleteBackward:", @"insertNewline:", @"insertTab:", @"cancelOperation:", @"moveLeft:"];
        Check([f.log isEqual:want], "text, commands, and F1 ignored");
        FakeEvent *cmdC = Key(@"c"); cmdC.modifierFlags = 1 << 20;   // Command-C is a key equivalent, not text
        [f.log removeAllObjects]; ShackInterpretKeyEvents(f, @[cmdC]);
        Check(f.log.count == 0, "command-modified keys insert nothing");
        Check(ShackKeyCodeForCharacter('a') == 0 && ShackKeyCodeForCharacter('A') == 0 && ShackKeyCodeForCharacter(' ') == 49 &&
              ShackKeyCodeForCharacter('\r') == 36 && ShackKeyCodeForCharacter(0x7f) == 51 && ShackKeyCodeForCharacter('1') == 18,
              "Mac key codes for typed characters");
        Check(ShackKeyCodeForCharacter(0x00E9) == 0xFFFF, "no key code for é");
        puts("text input ok");
    }
}
