#import <Foundation/Foundation.h>
// Intel games under AArchX (libOcerz), in MacShack and in MacShack Play: the game's main on the calling thread, or on a
// thread of its own that reports the end through ShackGuestEnded. Both need SHACK_JIT_POOL (ShackJITPoolSetup).
int ShackRunTranslated(NSString *exePath, NSArray<NSString *> *args);
BOOL ShackStartTranslated(NSString *exePath, NSArray<NSString *> *args, NSError **error);
// The game's Steam API (libShackSteamClient, `shim`): libOcerz's sem_open/shm_open/semctl/popen/pclose imports become the
// shim's (NO when it is not loaded); then, for a host symbol the game asks for, the shim's IPC answer or its stub where
// nothing else defines the name, NULL otherwise.
BOOL ShackTranslatedSteamUse(void *shim);
void *ShackTranslatedSteamSymbol(void *shim, const char *name);
