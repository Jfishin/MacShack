#import <Foundation/Foundation.h>

// The macOS Steam client's process layer on iOS: Steam Helper (Chromium) in-process under a fake pid. bundle is Steam's
// own folder (…/Steam.AppBundle/Steam), code its prepared copy (Library/Guests/SteamClient/Steam). Call before
// steam_osx starts.
void ShackSteamClientInstall(NSString *bundle, NSString *code);
