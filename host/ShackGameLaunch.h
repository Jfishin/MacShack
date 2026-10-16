#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Starting a Mac game in this process: MacShack Play (every game) and MacShack (the Steam client, ShackLoader.m).
// The launch dictionary (MacShack Play reads it as written by MacShack: <App Group>/Launch/current.plist):
//   app: the game's data bundle; code: its prepared code root; logs: the folder for <executable>.log; argsFile: its
//   .args (made with defaults when missing); translate: an Intel game (AArchX); fpsCap, renderScale, swapMB: numbers;
//   displaySize: "WxH" (optional); metalHUD: Metal's performance HUD (optional); home: HOME (optional, else this app's
//   container).
// Everything before the game's main: HOME, working folder, log, arguments, environment, hooks, frame cap, render
// scale, memory tier, forced resolution, engine conventions, pads. Main thread. Returns exePath, codePath, args, jitMB
// and watch, or nil with *error.
NSDictionary *_Nullable ShackGamePrepareProcess(NSDictionary *launch, NSError **error);
// Loads codePath on a new 64 MB thread named guest-main and runs its main there with argv0 and args (static
// initializers see the thread their main runs on). Returns once the image is loaded; with done, waits for main to
// return and puts its status in *rcOut. A main that returns without done ends the game (ShackGuestEnded).
BOOL ShackStartGuest(NSString *codePath, NSString *argv0, NSArray<NSString *> *_Nullable args, dispatch_semaphore_t _Nullable done,
                     int *_Nullable rcOut, NSError **error);
// A game's .args: one argument per line, MacShack's --shack-* tokens applied and left out (ShackGameLaunch.m).
NSArray<NSString *> *ShackGuestArgs(NSString *path, BOOL *watchOut, int *_Nullable jitMBOut, int *traceSecOut);
// The game's arguments from a launch dictionary: "args" as given (Steam's own, with nothing read or written), else its
// .args file (ShackGuestArgs). Without "args", MacShack's tokens in the file set *watchOut, *jitMBOut, *traceSecOut.
NSArray<NSString *> *ShackLaunchArgs(NSDictionary *launch, BOOL *watchOut, int *_Nullable jitMBOut, int *traceSecOut);
// stdout and stderr into logPath; the previous log stays as <name>.prev.log.
void ShackRedirectOutput(NSString *logPath);
NS_ASSUME_NONNULL_END
