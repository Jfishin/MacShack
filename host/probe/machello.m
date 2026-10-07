#import <Foundation/Foundation.h>
const char *machello(void) {
    NSString *s = [NSString stringWithFormat:@"hello from macOS SDK dylib, pid %d", [NSProcessInfo processInfo].processIdentifier];
    return strdup(s.UTF8String);
}
