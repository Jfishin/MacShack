#import <Foundation/Foundation.h>

// A developer check (--steam-load-probe): prepares and signs a macOS Steam client copied by hand to
// Library/Application Support/Steam, dlopens each image and logs the outcome to Documents/Logs/steam-load.log.
void ShackSteamLoadProbe(void);
// Prepares and signs the Steam client tree at source (…/Steam, Valve's files) into guest (…/Steam, removed first): every
// arm64 image but the programs Steam would start, symlinks as they are, then Steam Helper's and a game's private sets.
// progress (any thread, may be nil) gets images done and the total; `prepared` (may be nil) gets each prepared image's
// relative path. Returns "<image>: <reason>" per failure, empty when everything prepared.
NSArray<NSString *> *ShackSteamPrepare(NSString *source, NSString *guest, NSMutableArray<NSString *> *prepared,
                                       void (^progress)(NSUInteger done, NSUInteger total));
// Steam Helper's private images: Steam's original (bundle-relative) -> the prepared copy's path in the code folder.
NSDictionary<NSString *, NSString *> *ShackSteamHelperFiles(void);
// The same for the private Steam client API of a game Steam starts (steamclient_g and its tier0/vstdlib/audio).
NSDictionary<NSString *, NSString *> *ShackSteamGameFiles(void);
// Prepares and signs those not in the code folder yet (a Steam prepared by an older MacShack); before Steam starts.
void ShackSteamPrepareHelperFiles(void);
