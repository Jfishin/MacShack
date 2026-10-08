#import <Foundation/Foundation.h>
#import <mach/mach.h>

// The macOS Steam client's process layer on iOS: Steam Helper (Chromium) in-process under a fake pid. bundle is Steam's
// own folder (…/Steam.AppBundle/Steam), code its prepared copy (Library/Guests/SteamClient/Steam). Call before
// steam_osx starts.
void ShackSteamClientInstall(NSString *bundle, NSString *code);
// A send right to this Steam's ipcserver (com.valvesoftware.steam.ipctool, libShackSteamClient's in-process service; a
// first look-up starts ipcserver), for MacShack Play's Steam images; null without Steam.
mach_port_t ShackSteamClientIPCPort(void);
// Experiments with the Steam API in Windows games (lsteamclient; beside --steam-run): MacShack Play logs on to this
// Steam as the Windows program's stand-in pid, in `mode` "steam" (Valve's steamclient itself, query appid, seconds) or
// "run" (a Windows program through lsteamclient, query steam=1 and the program's). Play's Steam images are prepared first.
void ShackSteamPlaySteamProbe(NSString *mode, NSDictionary<NSString *, NSString *> *query);
