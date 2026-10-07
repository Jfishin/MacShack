#import "ShackTerminate.h"
#import <objc/message.h>

enum { TerminateCancel = 0, TerminateNow = 1, TerminateLater = 2 };   // NSApplicationTerminateReply
static BOOL gPendingLater;

static void Finish(id app, id delegate, void (^finish)(void)) {
    gPendingLater = NO;
    NSNotification *n = [NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:app];
    [NSNotificationCenter.defaultCenter postNotification:n];
    SEL will = NSSelectorFromString(@"applicationWillTerminate:");
    if ([delegate respondsToSelector:will]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, will, n);
    finish();
}

void ShackTerminateBegin(id app, id delegate, void (^finish)(void)) {
    NSUInteger reply = TerminateNow;
    SEL should = NSSelectorFromString(@"applicationShouldTerminate:");
    if ([delegate respondsToSelector:should]) reply = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(delegate, should, app);
    if (reply == TerminateCancel) return;                          // SDL2: it queued SDL_QUIT and quits by itself
    if (reply == TerminateLater) { gPendingLater = YES; return; }  // the game replies when it is done saving
    Finish(app, delegate, finish);
}

void ShackTerminateReply(BOOL shouldTerminate, id app, id delegate, void (^finish)(void)) {
    if (!gPendingLater) return;
    if (!shouldTerminate) { gPendingLater = NO; return; }
    Finish(app, delegate, finish);
}
