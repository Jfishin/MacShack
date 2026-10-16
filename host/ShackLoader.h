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
// Intel games (AArchX): engine default arguments and JIT pool size (the game's start: ShackTranslated.h).
NSArray<NSString *> *ShackTranslatedArgs(NSString *appPath, NSArray<NSString *> *args);
int ShackTranslatedJITMB(NSString *appPath);
const char *ShackPadIdentity(NSString *appPath);   // the virtual pad's identity for this game (SHACK_HID_PAD), NULL: default

@interface ShackLoader : NSObject
/// The macOS Steam client (prep/steam-onehost/README.md): its data is Steam's own folder, Library/Application Support/Steam,
/// its code the copy SteamSetup prepared in Library/Guests/SteamClient. Started like a game; extra arguments go
/// to steam_osx after Steam's own switches.
+ (BOOL)launchSteamClientWithArguments:(NSArray<NSString *> *)extra error:(NSError **)error;
/// Run a guest main() synchronously on a 64 MB thread and return its exit status (self-test).
+ (NSNumber *)runGuestMainAtPath:(NSString *)exePath home:(NSString *)home argv0:(NSString *)argv0 error:(NSError **)error;
@end
