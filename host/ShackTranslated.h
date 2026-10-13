#import <Foundation/Foundation.h>
// Intel games under AArchX (libOcerz), in MacShack and in MacShack Play: the game's main on the calling thread, or on a
// thread of its own that reports the end through ShackGuestEnded. Both need SHACK_JIT_POOL (ShackJITPoolSetup).
int ShackRunTranslated(NSString *exePath, NSArray<NSString *> *args);
BOOL ShackStartTranslated(NSString *exePath, NSArray<NSString *> *args, NSError **error);
