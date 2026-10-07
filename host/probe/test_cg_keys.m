// CGEventPost key events (shims/CG/ShackCG.m), replaying steamclient's on-screen keyboard calls:
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -framework UIKit -framework Metal \
//     -framework CoreGraphics -framework QuartzCore shims/CG/ShackCG.m host/probe/test_cg_keys.m -o /tmp/t && xcrun simctl spawn booted /tmp/t
// Expect "cg keys ok".
#import <Foundation/Foundation.h>

CFTypeRef CGEventCreateKeyboardEvent(CFTypeRef source, uint16_t keycode, bool down);
void CGEventKeyboardSetUnicodeString(CFTypeRef event, unsigned long length, const uint16_t *string);
void CGEventPost(uint32_t tap, CFTypeRef event);
CFTypeRef CGEventCreate(CFTypeRef source);

static NSMutableArray<NSString *> *posted;
__attribute__((visibility("default"))) void ShackAppKitPostKey(unsigned short keyCode, NSString *characters, BOOL down) {
    [posted addObject:[NSString stringWithFormat:@"%u %@ %@", keyCode, down ? @"down" : @"up", characters]];
}
static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }

int main(void) {
    posted = [NSMutableArray array];
    CFTypeRef e = CGEventCreateKeyboardEvent(NULL, 0, true);   // "Hi": one event, its string set per character
    for (NSUInteger i = 0; i < 2; i++) {
        UniChar c = [@"Hi" characterAtIndex:i];
        CGEventKeyboardSetUnicodeString(e, 1, &c);
        CGEventPost(0, e);
    }
    CFRelease(e);
    UInt16 codes[] = {51, 36, 123, 124, 125, 126};   // Delete, Return, arrows: key code alone
    for (int i = 0; i < 6; i++) { e = CGEventCreateKeyboardEvent(NULL, codes[i], true); CGEventPost(0, e); CFRelease(e); }
    e = CGEventCreate(NULL); CGEventPost(0, e); CFRelease(e);   // not a key event: nothing posted
    CGEventPost(0, NULL);
    NSArray *want = @[@"0 down H", @"0 down i", @"51 down \x7f", @"36 down \r", @"123 down ", @"124 down ",
                      @"125 down ", @"126 down "];
    Check([posted isEqualToArray:want], [posted.description UTF8String]);
    puts("cg keys ok");
    return 0;
}
