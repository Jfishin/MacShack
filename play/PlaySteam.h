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
