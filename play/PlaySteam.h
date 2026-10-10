#import <Foundation/Foundation.h>
#import <mach/mach.h>

// Steam's client images for this process (play/PlaySteam.m): hands `ipc` (MacShack's ipcserver, from the bridge) to
// libShackSteamClient, copies the set MacShack signed for Play out of the App Group and makes them see Steam's
// stand-in pid. Returns the folder holding steamclient.dylib (STEAM_COMPAT_CLIENT_INSTALL_PATH for lsteamclient), or
// nil with *error.
NSString *PlaySteamPrepare(NSURL *group, mach_port_t ipc, NSString **error);
// Valve's macOS steamclient in MacShack Play, logged on to MacShack's Steam (the first step toward the Steam API in
// Windows games, lsteamclient; play/PlaySteam.m).
// `ipc` is MacShack's ipcserver port (from the bridge); `say` gets each step. Returns a one-line verdict.
NSString *PlaySteamProbe(NSURL *group, mach_port_t ipc, uint32_t appID, unsigned seconds, void (^say)(NSString *line));
// A Mac game's own Steam API (a game Steam started, in MacShack Play): Play's steamclient set as above, seeing `pid`
// (Steam's stand-in for the game); each image under codeRoot that loads Valve's steamclient.dylib gets Play's signed
// steamclient_g, Steam's ipcserver through libShackSteamClient, and its SteamAPI_Init result logged. Call after the
// game's hooks are in and before its images load. Returns a report line.
NSString *PlaySteamForGame(NSURL *group, mach_port_t ipc, NSString *codeRoot, pid_t pid);
