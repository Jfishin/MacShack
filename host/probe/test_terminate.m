// Mac check: clang -fobjc-arc shims/AppKit/ShackTerminate.m host/probe/test_terminate.m -framework Foundation -o /tmp/tt && /tmp/tt
#import <Foundation/Foundation.h>
#import "../../shims/AppKit/ShackTerminate.h"

@interface Delegate : NSObject
@property NSUInteger reply; @property NSMutableArray<NSString *> *calls;
@end
@implementation Delegate
- (instancetype)init { if ((self = [super init])) _calls = [NSMutableArray array]; return self; }
- (NSUInteger)applicationShouldTerminate:(id)app { [_calls addObject:@"should"]; return _reply; }
- (void)applicationWillTerminate:(NSNotification *)n { [_calls addObject:@"will"]; }
@end

static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }

int main(void) {
    @autoreleasepool {
        __block int exits = 0; __block BOOL noted = NO;
        [NSNotificationCenter.defaultCenter addObserverForName:@"NSApplicationWillTerminateNotification" object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { noted = YES; }];
        void (^finish)(void) = ^{ exits++; };
        id app = [NSObject new];

        Delegate *now = [Delegate new]; now.reply = 1;
        ShackTerminateBegin(app, now, finish);
        Check(exits == 1 && noted && [now.calls isEqual:(@[@"should", @"will"])], "Now: should, notification, will, exit");

        exits = 0; noted = NO;
        Delegate *cancel = [Delegate new]; cancel.reply = 0;
        ShackTerminateBegin(app, cancel, finish);
        Check(exits == 0 && !noted && [cancel.calls isEqual:(@[@"should"])], "Cancel: nothing after should");
        ShackTerminateReply(YES, app, cancel, finish);
        Check(exits == 0, "a reply without a pending Later does nothing");

        Delegate *later = [Delegate new]; later.reply = 2;
        ShackTerminateBegin(app, later, finish);
        Check(exits == 0 && [later.calls isEqual:(@[@"should"])], "Later: waits");
        ShackTerminateReply(YES, app, later, finish);
        Check(exits == 1 && [later.calls isEqual:(@[@"should", @"will"])], "Later + reply YES: finishes");

        exits = 0;
        ShackTerminateBegin(app, later, finish);
        ShackTerminateReply(NO, app, later, finish);
        ShackTerminateReply(YES, app, later, finish);
        Check(exits == 0, "Later + reply NO: cancelled for good");

        exits = 0;
        ShackTerminateBegin(app, nil, finish);
        Check(exits == 1, "no delegate: exits");
        puts("terminate ok");
    }
}
