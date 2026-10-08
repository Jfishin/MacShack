// Mac check for host/ShackSteamPlay.m (Steam Play in MacShack's Steam): the steamclient patch table against this Mac's
// Steam (client 1788652215, the phone's build), universal and arm64-only copies, and the config text helpers.
// clang -fobjc-arc -Ihost host/ShackSteamPlay.m host/probe/test_steam_play.m -framework Foundation -o /tmp/t && /tmp/t
// Expect `steam play ok` (the patch part is skipped on a Mac without the Steam client).
#import "ShackSteamPlay.h"
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)

static NSString *scratch(NSString *name) { return [NSTemporaryDirectory() stringByAppendingPathComponent:name]; }

static NSUInteger differingBytes(NSData *a, NSData *b) {
    NSUInteger n = 0;
    const uint8_t *x = a.bytes, *y = b.bytes;
    for (NSUInteger i = 0; i < MIN(a.length, b.length); i++) n += x[i] != y[i];
    return n;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *steam = [NSHomeDirectory() stringByAppendingPathComponent:
                           @"Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"];
        if ([fm fileExistsAtPath:steam]) {
            NSString *fat = scratch(@"steamplay-fat.dylib"), *thin = scratch(@"steamplay-thin.dylib");
            [fm removeItemAtPath:fat error:nil];
            [fm removeItemAtPath:thin error:nil];
            CHECK([fm copyItemAtPath:steam toPath:fat error:nil]);
            CHECK(system([NSString stringWithFormat:@"lipo -thin arm64 '%@' -output '%@'", steam, thin].UTF8String) == 0);
            for (NSString *path in @[fat, thin]) {
                NSData *before = [NSData dataWithContentsOfFile:path];
                CHECK([ShackSteamPlayCheck(path) isEqualToString:@"would patch 3 site(s)"]);
                CHECK([[NSData dataWithContentsOfFile:path] isEqualToData:before]);   // the check writes nothing
                CHECK([ShackSteamPlayPatch(path) isEqualToString:@"patched 3 site(s)"]);
                CHECK([ShackSteamPlayCheck(path) isEqualToString:@"already patched"]);
                CHECK([ShackSteamPlayPatch(path) isEqualToString:@"already patched"]);
                NSData *after = [NSData dataWithContentsOfFile:path];
                CHECK(after.length == before.length);
                NSUInteger changed = differingBytes(before, after);
                CHECK(changed > 0 && changed <= 12);   // three instruction words at most
            }
            // Another build: one site holds something else, so nothing changes.
            CHECK(system([NSString stringWithFormat:@"lipo -thin arm64 '%@' -output '%@'", steam, thin].UTF8String) == 0);
            NSMutableData *other = [NSMutableData dataWithContentsOfFile:thin];
            uint32_t zero = 0;
            [other replaceBytesInRange:NSMakeRange(0x69382c, 4) withBytes:&zero];   // a dylib's __TEXT starts at 0
            CHECK([other writeToFile:thin atomically:YES]);
            CHECK([ShackSteamPlayPatch(thin) hasPrefix:@"not patched"]);
            CHECK([[NSData dataWithContentsOfFile:thin] isEqualToData:other]);
        } else {
            printf("no Steam client on this Mac: patch table not checked\n");
        }
        // Steam's global mapping: added once, under InstallConfigStore/Software/Valve/Steam.
        NSString *config = @"\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n"
                           @"\t\t\t\t\"AutoUpdateWindowEnabled\"\t\t\"0\"\n\t\t\t}\n\t\t}\n\t}\n}\n";
        NSString *mapped = ShackVDFAddCompatMapping(config, @"macshack_proton");
        CHECK([mapped containsString:@"\t\t\t{\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t\t\"0\"\n"]);
        CHECK([mapped containsString:@"\"name\"\t\t\"macshack_proton\""] && [mapped containsString:@"\"priority\"\t\t\"75\""]);
        CHECK([mapped hasSuffix:@"\"AutoUpdateWindowEnabled\"\t\t\"0\"\n\t\t\t}\n\t\t}\n\t}\n}\n"]);
        CHECK(ShackVDFAddCompatMapping(mapped, @"macshack_proton") == nil);
        CHECK(ShackVDFAddCompatMapping(@"\"UserLocalConfigStore\"\n{\n}\n", @"macshack_proton") == nil);   // another shape
        // A library: the next index, once.
        NSString *folders = @"\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/var/x/Steam\"\n\t\t\"apps\"\n\t\t{\n"
                            @"\t\t\t\"268910\"\t\t\"1\"\n\t\t}\n\t}\n}\n";
        NSString *added = ShackVDFAddLibrary(folders, @"/private/var/g/SteamLibrary", @"MacShack Play", @"42");
        CHECK([added containsString:@"\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"/private/var/g/SteamLibrary\"\n\t\t\"label\"\t\t\"MacShack Play\"\n\t\t\"contentid\"\t\t\"42\"\n"]);
        CHECK([added hasPrefix:[folders substringToIndex:folders.length - 2]] && [added hasSuffix:@"\t\t{\n\t\t}\n\t}\n}\n"]);
        CHECK(ShackVDFAddLibrary(added, @"/private/var/g/SteamLibrary", @"MacShack Play", @"42") == nil);
        // A Steam that never ran (new user): no config.vdf or libraryfolders.vdf yet. Setup writes them, with Steam's own
        // folder as library 0 and MacShack Play's as 1, and a second run changes nothing.
        NSString *fresh = scratch(@"steam-play-fresh"), *group = scratch(@"steam-play-group");
        [fm removeItemAtPath:fresh error:nil];
        [fm removeItemAtPath:group error:nil];
        [fm createDirectoryAtPath:fresh withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:group withIntermediateDirectories:YES attributes:nil error:nil];
        ShackSteamPlaySetup(fresh, [NSURL fileURLWithPath:group]);
        NSString *cfg = [NSString stringWithContentsOfFile:[fresh stringByAppendingPathComponent:@"config/config.vdf"] encoding:NSUTF8StringEncoding error:nil];
        CHECK([cfg hasPrefix:@"\"InstallConfigStore\"\n{\n"] && [cfg containsString:@"\"CompatToolMapping\""]);
        for (NSString *name in @[@"steamapps/libraryfolders.vdf", @"config/libraryfolders.vdf"]) {
            NSString *lib = [NSString stringWithContentsOfFile:[fresh stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
            CHECK(([lib hasPrefix:[NSString stringWithFormat:@"\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%@\"\n", fresh]]));
            CHECK(([lib containsString:[NSString stringWithFormat:@"\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%@/SteamLibrary\"\n\t\t\"label\"\t\t\"MacShack Play\"\n", group]]));
        }
        NSData *before = [NSData dataWithContentsOfFile:[fresh stringByAppendingPathComponent:@"steamapps/libraryfolders.vdf"]];
        ShackSteamPlaySetup(fresh, [NSURL fileURLWithPath:group]);
        CHECK([[NSData dataWithContentsOfFile:[fresh stringByAppendingPathComponent:@"steamapps/libraryfolders.vdf"]] isEqual:before]);
        // Removal undoes exactly that: the mapping (and its block once empty), the library entry; Steam's own text stays
        // byte for byte, and someone else's per-game mapping stays.
        CHECK([ShackVDFRemoveCompatMapping(mapped, @"macshack_proton") isEqualToString:config]);
        CHECK(ShackVDFRemoveCompatMapping(config, @"macshack_proton") == nil);
        NSString *perGame = [mapped stringByReplacingOccurrencesOfString:@"\t\t\t\t\t\"0\"\n" withString:
            @"\t\t\t\t\t\"268910\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"proton_9\"\n\t\t\t\t\t\t\"config\"\t\t\"\"\n"
            @"\t\t\t\t\t\t\"priority\"\t\t\"250\"\n\t\t\t\t\t}\n\t\t\t\t\t\"0\"\n"];
        NSString *kept = ShackVDFRemoveCompatMapping(perGame, @"macshack_proton");
        CHECK([kept containsString:@"\"268910\""] && [kept containsString:@"\"CompatToolMapping\""] && ![kept containsString:@"macshack_proton"]);
        CHECK([ShackVDFRemoveLibrary(added, @"/private/var/g/SteamLibrary") isEqualToString:folders]);
        CHECK(ShackVDFRemoveLibrary(folders, @"/private/var/g/SteamLibrary") == nil);
        // The whole switch off: the tool, the mapping and the library entry go; the library's files stay; twice is once.
        ShackSteamPlayRemove(fresh, [NSURL fileURLWithPath:group]);
        CHECK(![fm fileExistsAtPath:[fresh stringByAppendingPathComponent:@"compatibilitytools.d/macshack_proton"]]);
        cfg = [NSString stringWithContentsOfFile:[fresh stringByAppendingPathComponent:@"config/config.vdf"] encoding:NSUTF8StringEncoding error:nil];
        CHECK(![cfg containsString:@"CompatToolMapping"]);
        for (NSString *name in @[@"steamapps/libraryfolders.vdf", @"config/libraryfolders.vdf"]) {
            NSString *lib = [NSString stringWithContentsOfFile:[fresh stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
            CHECK(![lib containsString:@"SteamLibrary"] && [lib containsString:fresh]);
        }
        CHECK([fm fileExistsAtPath:[group stringByAppendingPathComponent:@"SteamLibrary/libraryfolder.vdf"]]);
        NSData *off = [NSData dataWithContentsOfFile:[fresh stringByAppendingPathComponent:@"config/config.vdf"]];
        ShackSteamPlayRemove(fresh, [NSURL fileURLWithPath:group]);
        CHECK([[NSData dataWithContentsOfFile:[fresh stringByAppendingPathComponent:@"config/config.vdf"]] isEqual:off]);
        CHECK(getenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS") == NULL);
        // A config.vdf that exists but is not UTF-8 is Steam's, not a missing file: setup leaves it byte for byte.
        NSString *odd = scratch(@"steam-play-odd");
        [fm removeItemAtPath:odd error:nil];
        [fm createDirectoryAtPath:[odd stringByAppendingPathComponent:@"config"] withIntermediateDirectories:YES attributes:nil error:nil];
        const uint8_t notUTF8[] = {0xff, 0xfe, 0x00};
        NSData *oddBytes = [NSData dataWithBytes:notUTF8 length:sizeof notUTF8];
        CHECK([oddBytes writeToFile:[odd stringByAppendingPathComponent:@"config/config.vdf"] atomically:YES]);
        ShackSteamPlaySetup(odd, [NSURL fileURLWithPath:group]);
        CHECK([[NSData dataWithContentsOfFile:[odd stringByAppendingPathComponent:@"config/config.vdf"]] isEqualToData:oddBytes]);
        // A Steam that never ran has nothing to undo: no file is written.
        NSString *never = scratch(@"steam-play-never");
        [fm removeItemAtPath:never error:nil];
        ShackSteamPlayRemove(never, nil);
        CHECK(![fm fileExistsAtPath:[never stringByAppendingPathComponent:@"config/config.vdf"]]);
        printf("steam play ok\n");
    }
    return 0;
}
