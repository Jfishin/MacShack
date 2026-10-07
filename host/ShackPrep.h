#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Native, unsigned Mach-O preparation. The caller supplies/signs each output and owns bundle layout.
@interface ShackPrep : NSObject
/// Magic-only discovery (including universal binaries); full validation happens during preparation.
+ (BOOL)isMachOAtPath:(NSString *)path;
/// Returns NO with an error for malformed input or a missing plain arm64 slice (arm64e is unsupported).
+ (BOOL)hasArm64AtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
/// The library an arm64 game's load command for this macOS install name is rewritten to: a Shack shim
/// (@rpath/libShack<X>.dylib) or the iOS framework without its Versions/ part; nil for a non-framework path.
/// AArchX (Intel games) opens the same libraries for its bridged calls.
+ (nullable NSString *)hostLibraryForInstallName:(NSString *)installName;
/// Unity's explicit/<revision> marker, when present. Does not execute or modify the binary.
+ (nullable NSString *)monoRevisionAtPath:(NSString *)path;
/// Input and executableDirectory must describe the same SOURCE tree. Output may be anywhere.
/// Keeps code/data offsets and dependency ordinals intact. Writes atomically; never signs or runs code.
+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath
                outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory
            mainExecutable:(BOOL)mainExecutable
                     error:(NSError * _Nullable * _Nullable)error;
/// For a binary prepared at a symlink's path (a framework's Name -> Versions/A/Name): loaderPathShift is the directory
/// it really lives in, relative to the directory it is prepared in ("Versions/A"), so its @loader_path rpaths and
/// dependencies still reach the files beside the real binary.
+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath
                outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory
            mainExecutable:(BOOL)mainExecutable
           loaderPathShift:(nullable NSString *)loaderPathShift
                     error:(NSError * _Nullable * _Nullable)error;
/// linkMap: extra library redirects checked before the usual ones, by framework name or by a full install name, to a
/// shim suffix ("SteamClient" -> @rpath/libShackSteamClient.dylib) or, when it starts with "@", a new install name used
/// as is (which also renames the binary's own LC_ID_DYLIB when that is the name mapped). The Steam client prepare uses it.
+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath
                outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory
            mainExecutable:(BOOL)mainExecutable
           loaderPathShift:(nullable NSString *)loaderPathShift
                   linkMap:(nullable NSDictionary<NSString *, NSString *> *)linkMap
                     error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
