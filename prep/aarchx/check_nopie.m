#import <Foundation/Foundation.h>
@interface Probe : NSObject
- (int)value;
@end
@implementation Probe
- (int)value { return 7; }
@end
static int one(void) { return 1; }
static int two(void) { return 2; }
static int (*table[])(void) = { one, two };
static const char *msg = "hello";
static NSString *const str = @"cfstring";
int main(void) {
    @autoreleasepool {
        int ok = table[0]() + table[1]() == 3;
        ok += msg[0] == 'h';
        ok += [str isEqualToString:@"cfstring"];
        ok += [[Probe new] value] == 7;
        printf("nopie %s (%p)\n", ok == 4 ? "ok" : "FAIL", (void *)main);
        return ok == 4 ? 0 : 1;
    }
}
