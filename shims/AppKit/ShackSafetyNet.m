#import "ShackAppKit.h"
#import <objc/runtime.h>

NSMethodSignature *ShackStubSignature(SEL sel) {
    const char *n = sel_getName(sel);
    if (n[0] == '_' || strncmp(n, "shack_", 6) == 0) return nil;   // runtime/KVC probes and our own hooks must miss
    char types[64] = "@@:"; size_t len = 3;
    for (const char *c = n; *c && len < sizeof types - 1; c++) if (*c == ':') types[len++] = '@';   // args ignored
    types[len] = 0;
    return [NSMethodSignature signatureWithObjCTypes:types];
}

void ShackStubInvoke(id self, NSInvocation *inv) {
    static NSMutableSet *seen; static dispatch_once_t o; dispatch_once(&o, ^{ seen = [NSMutableSet set]; });
    BOOL isClass = object_isClass(self);
    NSString *k = [NSString stringWithFormat:@"%c[%@ %@]", isClass ? '+' : '-', isClass ? self : [self class], NSStringFromSelector(inv.selector)];
    @synchronized(seen) { if (![seen containsObject:k]) { [seen addObject:k]; NSLog(@"[ShackAppKit] unimplemented %@", k); } }
    void *zero = NULL; [inv setReturnValue:&zero];
}
