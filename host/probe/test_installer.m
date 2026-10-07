// Mac transaction checks. The fake signer copies prepared bytes; it does not prove AMFI acceptance.
#import <Foundation/Foundation.h>
#import "../ShackInstaller.h"
#import "../ShackSigner.h"
#import <sys/stat.h>

static BOOL failSigning;
static NSString *profile = @"profile-one";
@implementation ShackSigner
+ (NSDictionary *)signingContextWithError:(NSError **)error {
    (void)error;
    return @{@"identifier": @"com.example.fixture", @"profileHash": profile,
             @"profileExpiration": [NSDate dateWithTimeIntervalSinceNow:3600]};
}
+ (BOOL)signBinaryAtPath:(NSString *)input outputPath:(NSString *)output error:(NSError **)error {
    if (failSigning) {
        if (error) *error = [NSError errorWithDomain:@"fixture" code:42 userInfo:nil];
        return NO;
    }
    return [NSFileManager.defaultManager copyItemAtPath:input toPath:output error:error];
}
+ (BOOL)importCertificateData:(NSData *)data password:(NSString *)password error:(NSError **)error { return NO; }
+ (NSString *)runProbeWithError:(NSError **)error { return nil; }
@end

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSString *App(NSString *root, NSString *name, NSString *fixture) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = [root stringByAppendingFormat:@"/Documents/Staging/%@.app", name];
    Check([fm createDirectoryAtPath:[path stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:nil error:nil], @"create app");
    Check([fm copyItemAtPath:fixture toPath:[path stringByAppendingPathComponent:@"Contents/MacOS/Main"] error:nil], @"copy fixture");
    Check([@{@"CFBundleExecutable": @"Main"} writeToFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES], @"write plist");
    Check([@"untouched game assets" writeToFile:[path stringByAppendingPathComponent:@"Contents/Assets"] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write data");
    return path;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        Check(argc == 5 || argc == 6, @"fixture arguments (arm64, x86_64, universal static library, arm64 with an @loader_path rpath[, i386])");
        NSString *root = [NSProcessInfo.processInfo.environment[@"SHACK_INSTALLER_TEST_ROOT"] stringByResolvingSymlinksInPath];
        NSString *fixture = [NSString stringWithUTF8String:argv[1]];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        NSString *source = App(root, @"Native", fixture);
        NSString *data = [root stringByAppendingPathComponent:@"Documents/Games/Native.app"];
        Check([ShackInstaller installAppAtPath:source error:&error] != nil, error.description);
        Check(![fm fileExistsAtPath:source] && [fm fileExistsAtPath:data], @"data moved after success");
        NSString *code = [ShackInstaller preparedCodeRootForAppPath:data error:&error];
        Check(code != nil, error.description);
        Check(![fm fileExistsAtPath:[code stringByAppendingPathComponent:@"Contents/Assets"]], @"data not copied to code cache");
        Check([[NSString stringWithContentsOfFile:[data stringByAppendingPathComponent:@"Contents/Assets"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"untouched game assets"], @"data unchanged");
        // A universal static library beside the code (Coromon's Firebase frameworks) is neither prepared nor signed.
        NSString *withArchive = App(root, @"Archive", fixture);
        NSString *archiveDir = [withArchive stringByAppendingPathComponent:@"Contents/Plugins/Static.framework"];
        Check([fm createDirectoryAtPath:archiveDir withIntermediateDirectories:YES attributes:nil error:nil] &&
              [fm copyItemAtPath:[NSString stringWithUTF8String:argv[3]] toPath:[archiveDir stringByAppendingPathComponent:@"Static"] error:nil], @"archive fixture");
        Check([ShackInstaller installAppAtPath:withArchive error:&error] != nil, error.description);
        // A Mac framework's top-level binary is a symlink to Versions/A/<Name> (Coromon's CoronaCards). It is prepared as a file
        // at the link's own path, which is what the load commands name once Versions/A is stripped. A downloader that dropped
        // symlinks leaves an empty file there instead; Versions/A/<Name> stands in for it.
        NSString *fwApp = App(root, @"Framework", fixture);
        NSString *linkFrameworks = [fwApp stringByAppendingPathComponent:@"Contents/Frameworks"];
        for (NSString *fw in @[@"Fw", @"Fw2"]) {
            NSString *base = [linkFrameworks stringByAppendingFormat:@"/%@.framework", fw];
            Check([fm createDirectoryAtPath:[base stringByAppendingString:@"/Versions/A"] withIntermediateDirectories:YES attributes:nil error:nil] &&
                  [fm copyItemAtPath:[NSString stringWithUTF8String:argv[4]] toPath:[base stringByAppendingFormat:@"/Versions/A/%@", fw] error:nil], @"framework fixture");
            if ([fw isEqual:@"Fw"]) Check([fm createSymbolicLinkAtPath:[base stringByAppendingPathComponent:fw] withDestinationPath:[@"Versions/A" stringByAppendingPathComponent:fw] error:nil] &&
                                          [fm createSymbolicLinkAtPath:[base stringByAppendingString:@"/Versions/Current"] withDestinationPath:@"A" error:nil], @"framework links");
            else Check([fm createFileAtPath:[base stringByAppendingPathComponent:fw] contents:nil attributes:nil], @"empty framework binary");
        }
        NSString *fwData = [root stringByAppendingPathComponent:@"Documents/Games/Framework.app"];
        Check([ShackInstaller installAppAtPath:fwApp error:&error] != nil, error.description);
        NSString *linkCode = [ShackInstaller preparedCodeRootForAppPath:fwData error:&error];
        Check(linkCode != nil, error.description);
        for (NSString *rel in @[@"Fw.framework/Fw", @"Fw.framework/Versions/A/Fw", @"Fw2.framework/Fw2", @"Fw2.framework/Versions/A/Fw2"]) {
            NSString *path = [linkCode stringByAppendingFormat:@"/Contents/Frameworks/%@", rel];
            struct stat st;
            Check(lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 1000, [@"prepared " stringByAppendingString:rel]);
        }
        // The link's copy looks for Frameworks/ beside the real binary; the real binary's copy is unchanged.
        NSData *flat = [NSData dataWithContentsOfFile:[linkCode stringByAppendingString:@"/Contents/Frameworks/Fw.framework/Fw"]];
        NSData *real = [NSData dataWithContentsOfFile:[linkCode stringByAppendingString:@"/Contents/Frameworks/Fw.framework/Versions/A/Fw"]];
        NSData *shifted = [@"@loader_path/Versions/A/Frameworks" dataUsingEncoding:NSUTF8StringEncoding], *plain = [@"@loader_path/Frameworks" dataUsingEncoding:NSUTF8StringEncoding];
        Check([flat rangeOfData:shifted options:0 range:NSMakeRange(0, flat.length)].location != NSNotFound, @"link copy's rpath reaches Versions/A/Frameworks");
        Check([real rangeOfData:plain options:0 range:NSMakeRange(0, real.length)].location != NSNotFound &&
              [real rangeOfData:shifted options:0 range:NSMakeRange(0, real.length)].location == NSNotFound, @"real binary's rpath unchanged");
        NSString *duplicate = App(root, @"Native", fixture);
        Check(![ShackInstaller installAppAtPath:duplicate error:&error] && [fm fileExistsAtPath:duplicate], @"same name leaves source intact");
        failSigning = YES;
        NSString *failed = App(root, @"Failure", fixture);
        Check(![ShackInstaller installAppAtPath:failed error:&error] && [fm fileExistsAtPath:failed], @"signer failure preserves source");
        Check(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Documents/Games/Failure.app"]], @"failure publishes no data");
        Check(![ShackInstaller installAppAtPath:data error:&error], @"reprepare fails with signer");
        Check([[ShackInstaller preparedCodeRootForAppPath:data error:&error] isEqual:code], @"failed reprepare retains previous prepared code");
        failSigning = NO;
        // Intel-only: translated by AArchX, so nothing is prepared or signed (the failing signer is never asked).
        failSigning = YES;
        NSString *intel = App(root, @"Intel", [NSString stringWithUTF8String:argv[2]]);
        NSString *intelData = [root stringByAppendingPathComponent:@"Documents/Games/Intel.app"];
        Check([ShackInstaller installAppAtPath:intel error:&error] != nil, error.description);
        Check(![fm fileExistsAtPath:intel] && [fm fileExistsAtPath:intelData], @"Intel data moved");
        Check([ShackInstaller translatesAtAppPath:intelData] && [ShackInstaller requiresJITAtAppPath:intelData], @"Intel game translated with JIT");
        Check([[ShackInstaller preparedCodeRootForAppPath:intelData error:&error] isEqual:intelData], @"Intel code root is its data folder");
        Check(![ShackInstaller translatesAtAppPath:data], @"arm64 game not translated");
        failSigning = NO;
        profile = @"profile-two";
        Check(![ShackInstaller preparedCodeRootForAppPath:data error:&error], @"profile change invalidates cache");
        Check([ShackInstaller installAppAtPath:data error:&error] != nil, error.description);
        NSString *renewed = [ShackInstaller preparedCodeRootForAppPath:data error:&error];
        Check(renewed && ![renewed isEqual:code], @"reprepare publishes new generation");
        NSString *bad = App(root, @"Symlink", fixture);
        Check([fm createSymbolicLinkAtPath:[bad stringByAppendingPathComponent:@"escape"] withDestinationPath:@"/etc/passwd" error:nil], @"create escape fixture");
        Check(![ShackInstaller installAppAtPath:bad error:&error] && [fm fileExistsAtPath:bad], @"external symlink rejected");
        NSString *mono = App(root, @"Mono", fixture);
        NSString *monoPath = [mono stringByAppendingPathComponent:@"Contents/MacOS/libmonobdwgc-2.0.dylib"];
        NSMutableData *monoBytes = [NSMutableData dataWithContentsOfFile:fixture];
        [monoBytes appendData:[@"explicit/deadbeef" dataUsingEncoding:NSUTF8StringEncoding]];
        [monoBytes writeToFile:monoPath atomically:YES];
        // A revision with no rebuilt runtime in Frameworks/MonoRuntimes keeps the game's own Mono (ShackTrapJIT.c).
        Check([ShackInstaller installAppAtPath:mono error:&error] != nil, error.description);
        NSString *monoData = [root stringByAppendingPathComponent:@"Documents/Games/Mono.app"];
        NSString *monoCode = [ShackInstaller preparedCodeRootForAppPath:monoData error:&error];
        NSData *keptMono = [NSData dataWithContentsOfFile:[monoCode stringByAppendingPathComponent:@"Contents/MacOS/libmonobdwgc-2.0.dylib"]];
        Check([keptMono rangeOfData:[@"explicit/deadbeef" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, keptMono.length)].location != NSNotFound,
              @"unknown Mono revision keeps the game's own Mono");
        Check([ShackInstaller requiresJITAtAppPath:monoData], @"game's own Mono requires JIT");
        // A Mono whose revision cannot be read is still refused, with the reason.
        NSString *anonymous = App(root, @"AnonymousMono", fixture);
        [fm copyItemAtPath:fixture toPath:[anonymous stringByAppendingPathComponent:@"Contents/MacOS/libmonobdwgc-2.0.dylib"] error:nil];
        Check(![ShackInstaller installAppAtPath:anonymous error:&error] && [fm fileExistsAtPath:anonymous] &&
              [error.localizedDescription containsString:@"Unity Mono revision"], @"unidentifiable Mono revision explained");
        // Valve's Steam API is prepared and signed like any library; it does not make the game need JIT.
        NSString *steamGame = App(root, @"SteamGame", fixture);
        [fm copyItemAtPath:fixture toPath:[steamGame stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"] error:nil];
        Check([ShackInstaller installAppAtPath:steamGame error:&error] != nil, error.description);
        NSString *steamData = [root stringByAppendingPathComponent:@"Documents/Games/SteamGame.app"];
        NSString *steamCode = [ShackInstaller preparedCodeRootForAppPath:steamData error:&error];
        Check([fm fileExistsAtPath:[steamCode stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"]] &&
              ![ShackInstaller requiresJITAtAppPath:steamData], @"Valve's Steam API prepared, no JIT");
        // A game the Steam client installed (steamapps/common) is prepared where it is: its data stays, Valve's Steam API
        // stays (Steam runs), and the prepared generation is reused until the game's code changes.
        NSString *steamApps = [root stringByAppendingPathComponent:@"Library/Application Support/Steam/steamapps/common/Client Game"];
        [fm createDirectoryAtPath:steamApps withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *clientGame = [steamApps stringByAppendingPathComponent:@"ClientGame.app"];
        Check([fm moveItemAtPath:App(root, @"ClientGame", fixture) toPath:clientGame error:nil], @"place the Steam client's game");
        [fm copyItemAtPath:fixture toPath:[clientGame stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"] error:nil];
        NSString *clientCode = [ShackInstaller steamGameCodeRootForAppPath:clientGame error:&error];
        Check(clientCode != nil, error.description);
        Check([fm fileExistsAtPath:[clientGame stringByAppendingPathComponent:@"Contents/Assets"]] &&
              ![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Documents/Games/ClientGame.app"]], @"Steam game's data stays in steamapps");
        Check([fm fileExistsAtPath:[clientCode stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"]], @"Steam game keeps Valve's Steam API");
        Check([[ShackInstaller steamGameCodeRootForAppPath:clientGame error:&error] isEqual:clientCode], @"Steam game's prepared code reused");
        NSString *clientMain = [clientGame stringByAppendingPathComponent:@"Contents/MacOS/Main"];
        NSMutableData *updated = [NSMutableData dataWithContentsOfFile:clientMain];
        [updated appendData:[@"steam update" dataUsingEncoding:NSUTF8StringEncoding]];
        [updated writeToFile:clientMain atomically:YES];
        NSString *afterUpdate = [ShackInstaller steamGameCodeRootForAppPath:clientGame error:&error];
        Check(afterUpdate && ![afterUpdate isEqual:clientCode], @"Steam game prepared again after Steam updates it");
        // An Intel game is translated where it is: Valve's library stays untouched.
        NSString *x86 = [NSString stringWithUTF8String:argv[2]];
        NSString *intelSteam = App(root, @"IntelSteam", x86);
        [fm copyItemAtPath:x86 toPath:[intelSteam stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"] error:nil];
        Check([ShackInstaller installAppAtPath:intelSteam error:&error] != nil, error.description);
        NSString *intelSteamData = [root stringByAppendingPathComponent:@"Documents/Games/IntelSteam.app"];
        Check([[NSData dataWithContentsOfFile:[intelSteamData stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"]] isEqual:[NSData dataWithContentsOfFile:x86]] &&
              ![fm fileExistsAtPath:[intelSteamData stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib.valve"]], @"Intel game's Valve library untouched");
        // i386-only (AArchX m32): translated like an Intel game.
        if (argc == 6) {
            NSString *old32 = App(root, @"Old32", [NSString stringWithUTF8String:argv[5]]);
            [fm copyItemAtPath:[NSString stringWithUTF8String:argv[5]] toPath:[old32 stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib"] error:nil];
            failSigning = YES;
            Check([ShackInstaller installAppAtPath:old32 error:&error] != nil, error.description);
            failSigning = NO;
            NSString *data32 = [root stringByAppendingPathComponent:@"Documents/Games/Old32.app"];
            NSDictionary *m32 = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"Library/Guests/Old32/current.plist"]];
            Check([m32[@"translate"] isEqual:@"i386"] && [ShackInstaller translatesAtAppPath:data32] && [ShackInstaller requiresJITAtAppPath:data32],
                  @"i386 game translated with JIT");
            Check([[ShackInstaller preparedCodeRootForAppPath:data32 error:&error] isEqual:data32], @"i386 code root is its data folder");
            Check(![fm fileExistsAtPath:[data32 stringByAppendingPathComponent:@"Contents/MacOS/libsteam_api.dylib.valve"]], @"i386 Valve library untouched");
        }
        // Native code inside a .framework folder (Godot GDExtensions: Fountains' EOS plugin) is signed like any dylib.
        NSString *fwGame = App(root, @"FrameworkGame", fixture);
        NSString *fwRelative = @"Contents/Frameworks/libplugin.framework/libSDK.dylib";
        [fm createDirectoryAtPath:[fwGame stringByAppendingPathComponent:fwRelative.stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm copyItemAtPath:fixture toPath:[fwGame stringByAppendingPathComponent:fwRelative] error:nil];
        Check([ShackInstaller installAppAtPath:fwGame error:&error] != nil, error.description);
        NSString *fwCode = [ShackInstaller preparedCodeRootForAppPath:[root stringByAppendingPathComponent:@"Documents/Games/FrameworkGame.app"] error:&error];
        Check([fm fileExistsAtPath:[fwCode stringByAppendingPathComponent:fwRelative]], @"dylib inside a .framework prepared");
        NSString *interrupted = App(root, @"Interrupted", fixture);
        NSString *interruptedData = [root stringByAppendingPathComponent:@"Documents/Games/Interrupted.app"];
        NSString *generation = NSUUID.UUID.UUIDString;
        NSString *privateRoot = [root stringByAppendingPathComponent:@"Library/Guests/Interrupted"];
        [fm createDirectoryAtPath:[privateRoot stringByAppendingPathComponent:generation] withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"generation": generation, @"movesData": @YES} writeToFile:[privateRoot stringByAppendingPathComponent:@"pending.plist"] atomically:YES];
        [fm moveItemAtPath:interrupted toPath:interruptedData error:nil];
        Check([ShackInstaller recoverInterruptedInstallsWithError:&error], error.description);
        Check([fm fileExistsAtPath:interrupted] && ![fm fileExistsAtPath:interruptedData], @"interrupted data rename rolls back");
        Check(![fm fileExistsAtPath:[privateRoot stringByAppendingPathComponent:generation]], @"partial code removed");
        // A kill during preparation leaves source data in staging and both private trees behind.
        NSString *early = App(root, @"Early", fixture);
        NSString *earlyRoot = [root stringByAppendingPathComponent:@"Library/Guests/Early"];
        NSString *earlyGeneration = NSUUID.UUID.UUIDString;
        NSString *earlyUnsigned = [earlyRoot stringByAppendingPathComponent:[@".work-" stringByAppendingString:earlyGeneration]];
        [fm createDirectoryAtPath:[earlyRoot stringByAppendingPathComponent:earlyGeneration] withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:earlyUnsigned withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"generation": earlyGeneration, @"movesData": @YES} writeToFile:[earlyRoot stringByAppendingPathComponent:@"pending.plist"] atomically:YES];
        Check([ShackInstaller recoverInterruptedInstallsWithError:&error], error.description);
        Check([fm fileExistsAtPath:early] && ![fm fileExistsAtPath:earlyUnsigned] &&
              ![fm fileExistsAtPath:[earlyRoot stringByAppendingPathComponent:earlyGeneration]], @"early crash removes private trees and preserves source");
        NSString *mainData = [data stringByAppendingPathComponent:@"Contents/MacOS/Main"];
        NSData *originalMain = [NSData dataWithContentsOfFile:mainData];
        [@"updated game binary" writeToFile:mainData atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(![ShackInstaller preparedCodeRootForAppPath:data error:&error] &&
              [error.localizedDescription containsString:@"original code changed"], @"source update requires reprepare");
        [originalMain writeToFile:mainData atomically:YES];
        [@"damaged" writeToFile:[renewed stringByAppendingPathComponent:@"Contents/MacOS/Main"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(![ShackInstaller preparedCodeRootForAppPath:data error:&error], @"changed signed code rejected");
        puts("PASS: staged import, Valve's Steam API kept, Steam client game in place, data preservation, rejection, signing failure, reprepare, profile invalidation, crash rollback, code integrity");
    }
}
