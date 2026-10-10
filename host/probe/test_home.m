// Mac check of the shared home (host/ShackHome.m) on scratch folders, never the Mac's own Library:
//   clang -fobjc-arc -Ihost host/ShackHome.m host/probe/test_home.m -framework Foundation -o /tmp/t && /tmp/t
// expect `home move ok`.
#import "ShackHome.h"
#import <sys/stat.h>

static void check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }
static NSString *readText(NSString *p) { return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL]; }
static void writeText(NSString *p, NSString *s) {
    [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static NSString *linkOf(NSString *p) { return [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:p error:NULL]; }

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *container = [scratch stringByAppendingPathComponent:@"container"], *home = [scratch stringByAppendingPathComponent:@"group/Home"];
        NSArray *folders = @[@"Library/Application Support", @"Library/Logs"];
        NSString *as = [container stringByAppendingPathComponent:@"Library/Application Support"], *sharedAS = [home stringByAppendingPathComponent:@"Library/Application Support"];
        // First start: Steam and a save move, the folder becomes a link; Logs is missing and just gets its link.
        writeText([as stringByAppendingPathComponent:@"Steam/config/config.vdf"], @"steam");
        writeText([as stringByAppendingPathComponent:@"Game/save1"], @"mine");
        writeText([home stringByAppendingPathComponent:@"Library/Application Support/Game/save1"], @"older, from Play");
        [fm createDirectoryAtPath:[home stringByAppendingPathComponent:@"Library/Application Support/ShackProbe"] withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createSymbolicLinkAtPath:[as stringByAppendingPathComponent:@"ShackProbe"] withDestinationPath:[sharedAS stringByAppendingPathComponent:@"ShackProbe"] error:NULL];
        NSString *report = ShackHomeLink(container, home, folders);
        check([linkOf(as) isEqual:sharedAS], "Application Support is a link to the shared home");
        check([readText([sharedAS stringByAppendingPathComponent:@"Steam/config/config.vdf"]) isEqual:@"steam"], "Steam moved");
        check([readText([as stringByAppendingPathComponent:@"Steam/config/config.vdf"]) isEqual:@"steam"], "and reached through the link");
        check([readText([sharedAS stringByAppendingPathComponent:@"Game/save1"]) isEqual:@"mine"], "the container's copy wins");
        NSArray *aside = [[fm contentsOfDirectoryAtPath:sharedAS error:NULL] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'Game (set aside'"]];
        check(aside.count == 1 && [readText([[sharedAS stringByAppendingPathComponent:aside[0]] stringByAppendingPathComponent:@"save1"]) isEqual:@"older, from Play"], "the group's clash set aside");
        check([fm fileExistsAtPath:[sharedAS stringByAppendingPathComponent:@"ShackProbe"]] && !linkOf([sharedAS stringByAppendingPathComponent:@"ShackProbe"]), "a link into the home is dropped, not moved");
        check([linkOf([container stringByAppendingPathComponent:@"Library/Logs"]) isEqual:[home stringByAppendingPathComponent:@"Library/Logs"]], "a missing folder gets its link");
        check([report containsString:@"moved"], "the report says what moved");
        // Second start: nothing to do.
        check([ShackHomeLink(container, home, folders) containsString:@"linked"] && [linkOf(as) isEqual:sharedAS], "again: already linked");
        // The App Group's path changed (a restore): the link is pointed at the new one.
        NSString *home2 = [scratch stringByAppendingPathComponent:@"group2/Home"];
        ShackHomeLink(container, home2, folders);
        check([linkOf(as) isEqual:[home2 stringByAppendingPathComponent:@"Library/Application Support"]], "a stale link is re-pointed");
        // iOS refuses a rename: what moved stays moved, the rest stays, no link, the report says so.
        NSString *c3 = [scratch stringByAppendingPathComponent:@"container3"], *h3 = [scratch stringByAppendingPathComponent:@"group3/Home"];
        NSString *as3 = [c3 stringByAppendingPathComponent:@"Library/Application Support"];
        writeText([as3 stringByAppendingPathComponent:@"Kept/file"], @"kept");
        [fm createDirectoryAtPath:[h3 stringByAppendingPathComponent:@"Library/Application Support"] withIntermediateDirectories:YES attributes:nil error:NULL];
        chmod([h3 stringByAppendingPathComponent:@"Library/Application Support"].fileSystemRepresentation, 0555);
        NSString *refused = ShackHomeLink(c3, h3, @[@"Library/Application Support"]);
        chmod([h3 stringByAppendingPathComponent:@"Library/Application Support"].fileSystemRepresentation, 0755);
        check(!linkOf(as3) && [readText([as3 stringByAppendingPathComponent:@"Kept/file"]) isEqual:@"kept"], "refused: the folder and its data stay");
        check([refused containsString:@"refused"], "refused: reported");
        // Settings: newer wins in both directions, and a sync right after changes nothing. The values go through the
        // Mac's real cfprefsd (a throwaway domain, removed at the end); the decisions read file dates in scratch folders.
        NSString *domain = [@"com.example.shackprefs." stringByAppendingString:NSUUID.UUID.UUIDString];
        CFStringRef app = (__bridge CFStringRef)domain;
        NSString *local = [scratch stringByAppendingPathComponent:@"localPrefs"], *shared = [scratch stringByAppendingPathComponent:@"sharedPrefs"];
        NSString *file = [domain stringByAppendingPathExtension:@"plist"];
        NSString *localFile = [local stringByAppendingPathComponent:file], *sharedFile = [shared stringByAppendingPathComponent:file];
        [fm createDirectoryAtPath:local withIntermediateDirectories:YES attributes:nil error:NULL];
        CFPreferencesSetAppValue(CFSTR("volume"), (__bridge CFNumberRef)@7, app);
        CFPreferencesAppSynchronize(app);
        [@{} writeToFile:localFile atomically:YES];   // stands for cfprefsd's file: only its date counts
        check([ShackPrefsSync(local, shared, @[]) containsString:@"0 in, 1 out"] &&
              [[NSDictionary dictionaryWithContentsOfFile:sharedFile][@"volume"] isEqual:@7], "local newer: exported");
        check([ShackPrefsSync(local, shared, @[]) containsString:@"0 in, 0 out"], "right after: nothing to do");
        [@{@"volume": @9} writeToFile:sharedFile atomically:YES];
        [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:60]} ofItemAtPath:sharedFile error:NULL];
        check([ShackPrefsSync(local, shared, @[@"com.example."]) containsString:@"0 in, 0 out"], "skipped prefixes are left alone");
        check([ShackPrefsSync(local, shared, @[]) containsString:@"1 in, 0 out"] &&
              [CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("volume"), app)) isEqual:@9], "shared newer: imported");
        CFPreferencesSetMultiple(NULL, (__bridge CFArrayRef)@[@"volume"], app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesAppSynchronize(app);
        [fm removeItemAtPath:[NSHomeDirectory() stringByAppendingFormat:@"/Library/Preferences/%@", file] error:NULL];
        [fm removeItemAtPath:scratch error:NULL];
        puts("home move ok");
    }
}
