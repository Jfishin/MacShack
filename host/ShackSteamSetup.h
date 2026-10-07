#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Valve's macOS Steam client packages, for host/SteamSetup.swift. Each returns nil on success, else what went wrong.
// A package zip into dir (Steam/Contents/MacOS): `\` separates too; an entry that is absolute or has a `..` component,
// or a symlink pointing above dir, stops the unpack before anything of it is written.
NSString *_Nullable ShackSteamUnzip(NSString *zip, NSString *dir);
// Steam.app's own files (Info.plist, embedded.provisionprofile, Resources/Assets.car, Resources/Steam.icns) from
// SteamMacBootstrapper.tar.gz (appdmg_osx's, unpacked into MacOS like every package) into contents (Steam/Contents).
NSString *_Nullable ShackSteamUnpackSkeleton(NSString *tarGz, NSString *contents);
NS_ASSUME_NONNULL_END
