#import <Foundation/Foundation.h>
// Game lifetime, for the host UI (ShackHooks.m; ShackAppKitRequestQuit is implemented by libShackAppKit).
void ShackGuestEnded(int code);
void ShackExitProcess(int code);
void ShackAppKitRequestQuit(void);
void ShackAppKitToggleKeyboard(void);   // libShackAppKit: the iOS keyboard for the running game
// Power: frame caps and render scales (ShackLoader.m), live where it can be (ShackMetal.m, libShackCV, libShackAppKit).
int ShackGameFrameCap(NSString *name, BOOL translate);
double ShackGameRenderScale(NSString *name, BOOL translate);   // 0 = the panel's own
int ShackSteamUIFrameCap(void);
double ShackSteamUIRenderScale(void);
void ShackMetalSetFrameCap(int fps);   // 0 = uncapped; takes effect at the next frame
int ShackMetalFrameCap(void);
void ShackAppKitSetRenderScale(double scale);   // for windows and views from now on; 0 = the panel's own
NSString *ShackSteamClientGameName(void);   // the game the Steam client runs now, nil if none
// Intel games (AArchX): engine default arguments, JIT pool size, and the game's main run on the calling thread.
NSArray<NSString *> *ShackTranslatedArgs(NSString *appPath, NSArray<NSString *> *args);
int ShackTranslatedJITMB(NSString *appPath);
BOOL ShackWantsXbox2016(NSString *appPath);   // the virtual pad's 2016 identity (Rewired games)
int ShackRunTranslated(NSString *exePath, NSArray<NSString *> *args);

@interface ShackLoader : NSObject
/// Validate prepared/embedded code before installing process-wide guest hooks.
+ (BOOL)validateAppAtPath:(NSString *)appPath error:(NSError **)error;
/// Launch Documents/Games/<Name>.app from private prepared code or legacy embedded code; the game sees the Documents path. On success the guest owns the process and this never returns
/// meaningfully; on failure returns NO with dlerror()/reason in error.
+ (BOOL)launchAppAtPath:(NSString *)appPath error:(NSError **)error;
/// The macOS Steam client (prep/steam-onehost/README.md): its data is Steam's own folder, Library/Application Support/Steam,
/// its code the copy --steam-load-probe prepared in Library/Guests/SteamClient. Started like a game; extra arguments go
/// to steam_osx after Steam's own switches.
+ (BOOL)launchSteamClientWithArguments:(NSArray<NSString *> *)extra error:(NSError **)error;
/// Run a guest main() synchronously on a 64 MB thread and return its exit status (self-test).
+ (NSNumber *)runGuestMainAtPath:(NSString *)exePath home:(NSString *)home argv0:(NSString *)argv0 error:(NSError **)error;
@end
