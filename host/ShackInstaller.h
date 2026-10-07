#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Imports a clean macOS app from Documents/Staging. Call on a background queue.
@interface ShackInstaller : NSObject
+ (nullable NSString *)installAppAtPath:(NSString *)appPath error:(NSError **)error;
/// Returns nil without an error when this game has no on-device installation.
+ (nullable NSString *)preparedCodeRootForAppPath:(NSString *)appPath error:(NSError **)error;
/// A game Steam installed and starts (steamapps/common/...): its arm64 code is prepared and signed into
/// Library/Guests/Steam.<app name>, its data stays where Steam keeps it, and Valve's Steam API stays (Steam runs).
/// The prepared generation is reused while its sources, MacShack and the signing profile are unchanged.
/// An Intel one runs under AArchX from its own folder (the code root returned).
+ (nullable NSString *)steamGameCodeRootForAppPath:(NSString *)appPath error:(NSError **)error;
/// That game's install record (requiresJIT, translate), in Library/Guests/Steam.<app name>.
+ (nullable NSDictionary *)steamGameManifestForAppPath:(NSString *)appPath;
+ (BOOL)requiresJITAtAppPath:(NSString *)appPath;
/// An Intel (x86_64-only) game, run under AArchX translation rather than prepared and signed.
+ (BOOL)translatesAtAppPath:(NSString *)appPath;
/// Restores staged data after an interrupted, uncommitted import. Call before scanning games.
+ (BOOL)recoverInterruptedInstallsWithError:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
