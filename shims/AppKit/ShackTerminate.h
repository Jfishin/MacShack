#import <Foundation/Foundation.h>
// The Mac quit sequence behind -[NSApplication terminate:] and -replyToApplicationShouldTerminate:. Foundation only, so
// it has a Mac test (host/probe/test_terminate.m). `finish` performs the exit (the loader turns it into "game ended").
void ShackTerminateBegin(id app, id delegate, void (^finish)(void));
void ShackTerminateReply(BOOL shouldTerminate, id app, id delegate, void (^finish)(void));
