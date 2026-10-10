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
static void forget(NSString *domain) {   // `defaults delete`, quietly (the domain may not exist yet)
    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/defaults";
    task.arguments = @[@"delete", domain];
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launch];
    [task waitUntilExit];
}

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
        // Refused half-way: Steam moved, then a folder iOS will not move. Steam must still be reached from the container
        // (a link to where it went), and the next start finishes the move without setting the real Steam aside.
        NSString *c4 = [scratch stringByAppendingPathComponent:@"container4"], *h4 = [scratch stringByAppendingPathComponent:@"group4/Home"];
        NSString *as4 = [c4 stringByAppendingPathComponent:@"Library/Application Support"], *shared4 = [h4 stringByAppendingPathComponent:@"Library/Application Support"];
        writeText([as4 stringByAppendingPathComponent:@"Steam/config/config.vdf"], @"signed in");
        writeText([as4 stringByAppendingPathComponent:@"Zlocked/file"], @"z");
        chmod([as4 stringByAppendingPathComponent:@"Zlocked"].fileSystemRepresentation, 0555);   // a folder can only move with write access to itself
        NSString *half = ShackHomeLink(c4, h4, @[@"Library/Application Support"]);
        check([half containsString:@"refused"] && [half containsString:@"Steam"], "half-way: reported with what moved");
        check(!linkOf(as4) && [readText([as4 stringByAppendingPathComponent:@"Steam/config/config.vdf"]) isEqual:@"signed in"], "half-way: the moved Steam is still reached from the container");
        chmod([as4 stringByAppendingPathComponent:@"Zlocked"].fileSystemRepresentation, 0755);
        ShackHomeLink(c4, h4, @[@"Library/Application Support"]);
        check([linkOf(as4) isEqual:shared4] && [readText([shared4 stringByAppendingPathComponent:@"Steam/config/config.vdf"]) isEqual:@"signed in"] &&
              [readText([shared4 stringByAppendingPathComponent:@"Zlocked/file"]) isEqual:@"z"], "next start: the move finishes");
        check(![[fm contentsOfDirectoryAtPath:shared4 error:NULL] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS 'set aside'"]].count, "next start: nothing set aside");
        // Two clashes on one name within a minute: both earlier copies are kept under different names.
        NSString *c5 = [scratch stringByAppendingPathComponent:@"container5"], *h5 = [scratch stringByAppendingPathComponent:@"group5/Home"];
        NSString *as5 = [c5 stringByAppendingPathComponent:@"Library/Application Support"], *shared5 = [h5 stringByAppendingPathComponent:@"Library/Application Support"];
        writeText([shared5 stringByAppendingPathComponent:@"Game/save"], @"v0");
        writeText([as5 stringByAppendingPathComponent:@"Game/save"], @"v1");
        ShackHomeLink(c5, h5, @[@"Library/Application Support"]);
        [fm removeItemAtPath:as5 error:NULL];   // the link: a container with its own copy again
        writeText([as5 stringByAppendingPathComponent:@"Game/save"], @"v2");
        ShackHomeLink(c5, h5, @[@"Library/Application Support"]);
        NSArray *kept = [[fm contentsOfDirectoryAtPath:shared5 error:NULL] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'Game (set aside'"]];
        NSMutableSet *versions = [NSMutableSet set];
        for (NSString *k in kept) [versions addObject:readText([[shared5 stringByAppendingPathComponent:k] stringByAppendingPathComponent:@"save"]) ?: @""];
        check([linkOf(as5) isEqual:shared5] && [readText([shared5 stringByAppendingPathComponent:@"Game/save"]) isEqual:@"v2"] &&
              [versions isEqual:[NSSet setWithObjects:@"v0", @"v1", nil]], "two clashes in a minute: both earlier copies kept");
        // Settings: each app keeps what it last synced per domain; the side that changed since then wins (both changed:
        // the newer file), keys deleted there go here too, and a sync right after changes nothing. Values go through the
        // Mac's real cfprefsd (one fixed throwaway domain, cleared through `defaults` at the start and the end: cfprefsd
        // may still write its empty file a few seconds later, so at most this one small file stays); file dates are
        // scratch files.
        NSString *domain = @"com.example.shackprefs.test";
        CFStringRef app = (__bridge CFStringRef)domain;
        forget(domain);
        NSString *local = [scratch stringByAppendingPathComponent:@"localPrefs"], *shared = [scratch stringByAppendingPathComponent:@"sharedPrefs"];
        NSString *synced = [scratch stringByAppendingPathComponent:@"syncedPrefs"];
        NSString *file = [domain stringByAppendingPathExtension:@"plist"];
        NSString *localFile = [local stringByAppendingPathComponent:file], *sharedFile = [shared stringByAppendingPathComponent:file];
        id (^value)(NSString *) = ^id(NSString *key) { return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, app)); };
        void (^set)(NSString *, id) = ^(NSString *key, id v) { CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)v, app); CFPreferencesAppSynchronize(app); };
        [fm createDirectoryAtPath:local withIntermediateDirectories:YES attributes:nil error:NULL];
        set(@"volume", @7);
        [@{} writeToFile:localFile atomically:YES];   // stands for cfprefsd's file: only its date counts
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"0 in, 1 out"] &&
              [[NSDictionary dictionaryWithContentsOfFile:sharedFile][@"volume"] isEqual:@7], "first sync: exported");
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"0 in, 0 out"], "right after: nothing to do");
        [@{@"volume": @9} writeToFile:sharedFile atomically:YES];   // the other app changed it
        check([ShackPrefsSync(local, shared, synced, @[@"com.example."]) containsString:@"0 in, 0 out"], "skipped prefixes are left alone");
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"1 in, 0 out"] && [value(@"volume") isEqual:@9], "changed there: imported");
        set(@"volume", @11);   // changed here just before the sync; cfprefsd's file date comes seconds later
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"0 in, 1 out"] &&
              [[NSDictionary dictionaryWithContentsOfFile:sharedFile][@"volume"] isEqual:@11], "changed here, file date late: still exported");
        set(@"music", @1);
        ShackPrefsSync(local, shared, synced, @[]);
        [@{@"volume": @11} writeToFile:sharedFile atomically:YES];   // the other app deleted "music"
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"1 in, 0 out"] && !value(@"music"), "a key deleted there goes here too");
        set(@"volume", @12);
        [@{@"volume": @13} writeToFile:sharedFile atomically:YES];
        [fm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:60]} ofItemAtPath:sharedFile error:NULL];
        check([ShackPrefsSync(local, shared, synced, @[]) containsString:@"1 in, 0 out"] && [value(@"volume") isEqual:@13], "both changed: the newer file wins");
        forget(domain);
        [fm removeItemAtPath:scratch error:NULL];
        puts("home move ok");
    }
}
