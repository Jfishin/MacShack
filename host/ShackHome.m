#import "ShackHome.h"
#include <errno.h>
#include <stdio.h>

// MacShack's bundle id (Play's is MacShack's + ".play"), read at load: once a game's hooks are in, mainBundle answers
// for the game.
static NSString *gHostID;
__attribute__((constructor)) static void captureHostID(void) {
    NSString *mine = NSBundle.mainBundle.bundleIdentifier;
    gHostID = [mine hasSuffix:@".play"] ? mine.stringByDeletingPathExtension : mine;
}

// A free name for an item set aside in folder: "<name> (set aside <date and time>)", then " 2", " 3"... (a rename onto a
// taken name would replace a file there).
static NSString *asideName(NSString *folder, NSString *name) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HHmmss";
    NSString *base = [NSString stringWithFormat:@"%@ (set aside %@)", name, [f stringFromDate:NSDate.date]], *aside = base;
    for (int n = 2; [NSFileManager.defaultManager attributesOfItemAtPath:[folder stringByAppendingPathComponent:aside] error:NULL]; n++)
        aside = [NSString stringWithFormat:@"%@ %d", base, n];
    return [folder stringByAppendingPathComponent:aside];
}

// A move that stopped: what already moved stays reachable from the container through a link each (the next start drops
// those links as leading into the home and moves the rest).
static NSString *stopped(NSString *mine, NSString *shared, NSArray<NSString *> *moved, NSString *why) {
    for (NSString *name in moved)
        [NSFileManager.defaultManager createSymbolicLinkAtPath:[mine stringByAppendingPathComponent:name] withDestinationPath:[shared stringByAppendingPathComponent:name] error:NULL];
    return moved.count ? [NSString stringWithFormat:@"%@; moved so far (linked back): %@", why, [moved componentsJoinedByString:@", "]] : why;
}

// One folder. ponytail: clashes are settled per top-level entry (a game's whole folder), not merged file by file.
static NSString *linkFolder(NSString *container, NSString *home, NSString *folder) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *mine = [container stringByAppendingPathComponent:folder], *shared = [home stringByAppendingPathComponent:folder];
    NSError *e = nil;
    if (![fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:&e])
        return [NSString stringWithFormat:@"%@: FAILED, no shared folder: %@", folder, e.localizedDescription];
    NSString *type = [fm attributesOfItemAtPath:mine error:NULL].fileType;
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        NSString *to = [fm destinationOfSymbolicLinkAtPath:mine error:NULL];
        if ([to isEqualToString:shared]) return [folder stringByAppendingString:@": linked"];
        [fm removeItemAtPath:mine error:NULL];   // the link only
        BOOL ok = [fm createSymbolicLinkAtPath:mine withDestinationPath:shared error:&e];
        return [NSString stringWithFormat:@"%@: %@ (was %@)", folder, ok ? @"link pointed at the shared home again" : [@"FAILED to re-point: " stringByAppendingString:e.localizedDescription], to];
    }
    NSMutableArray<NSString *> *moved = [NSMutableArray array], *setAside = [NSMutableArray array];
    if (type) {   // a real folder: its entries move
        for (NSString *name in [[fm contentsOfDirectoryAtPath:mine error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *from = [mine stringByAppendingPathComponent:name], *to = [shared stringByAppendingPathComponent:name];
            if ([[fm attributesOfItemAtPath:from error:NULL].fileType isEqualToString:NSFileTypeSymbolicLink] &&
                [[fm destinationOfSymbolicLinkAtPath:from error:NULL] hasPrefix:home]) {   // already leads into the home
                [fm removeItemAtPath:from error:NULL];
                continue;
            }
            if ([fm fileExistsAtPath:to] || [fm attributesOfItemAtPath:to error:NULL]) {
                NSString *aside = asideName(shared, name);
                if (rename(to.fileSystemRepresentation, aside.fileSystemRepresentation))
                    return stopped(mine, shared, moved, [NSString stringWithFormat:@"%@: rename refused (%s) setting aside %@", folder, strerror(errno), name]);
                [setAside addObject:name];
            }
            if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation))
                return stopped(mine, shared, moved, [NSString stringWithFormat:@"%@: rename refused (%s) for %@: left in the container", folder, strerror(errno), name]);
            [moved addObject:name];
        }
        if (rmdir(mine.fileSystemRepresentation))
            return stopped(mine, shared, moved, [NSString stringWithFormat:@"%@: FAILED, folder not empty after the move (%s)", folder, strerror(errno)]);
    } else {
        [fm createDirectoryAtPath:mine.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    if (![fm createSymbolicLinkAtPath:mine withDestinationPath:shared error:&e]) {
        [fm createDirectoryAtPath:mine withIntermediateDirectories:YES attributes:nil error:NULL];   // the folder back, its entries linked
        return stopped(mine, shared, moved, [NSString stringWithFormat:@"%@: FAILED to link: %@", folder, e.localizedDescription]);
    }
    return [NSString stringWithFormat:@"%@: moved %lu (%@)%@, linked", folder, (unsigned long)moved.count, [moved componentsJoinedByString:@", "],
            setAside.count ? [NSString stringWithFormat:@"; set aside from the shared home: %@", [setAside componentsJoinedByString:@", "]] : @""];
}

NSString *ShackHomeLink(NSString *container, NSString *home, NSArray<NSString *> *folders) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *folder in folders) [lines addObject:linkFolder(container, home, folder)];
    return [lines componentsJoinedByString:@"\n"];
}

NSString *ShackHomeGroup(void) {
    return gHostID ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[@"group." stringByAppendingString:gHostID]].path : nil;
}

NSString *ShackHomeEnsure(void) {
    NSString *group = ShackHomeGroup();
    if (!group) return @"shared home: no App Group container";
    NSString *report = ShackHomeLink(NSHomeDirectory(), [group stringByAppendingPathComponent:@"Home"], @[@"Library/Application Support", @"Library/Logs"]);
    NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [logs stringByAppendingPathComponent:@"shared-home.txt"];
    NSString *line = [NSString stringWithFormat:@"%@  %@ %@\n", NSDate.date, NSBundle.mainBundle.bundleIdentifier,
                      [report stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (file) { [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile]; }
    else [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[MacShack] shared home: %@", report);
    return report;
}

static NSDate *modified(NSString *path) { return [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileModificationDate; }
// a later than b: a date copied onto a file comes back a fraction of a microsecond off, so 10 ms or less is the same time.
static BOOL later(NSDate *a, NSDate *b) { return a && (!b || [a timeIntervalSinceDate:b] > 0.01); }

static BOOL writePlist(id value, NSString *path) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:NULL];
}

NSString *ShackPrefsSync(NSString *localPrefs, NSString *sharedPrefs, NSString *syncedPrefs, NSArray<NSString *> *skipPrefixes) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *folder in @[sharedPrefs, syncedPrefs]) [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableSet<NSString *> *domains = [NSMutableSet set];
    for (NSString *folder in @[localPrefs, sharedPrefs, syncedPrefs])
        for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:NULL])
            if ([name.pathExtension isEqualToString:@"plist"]) [domains addObject:name.stringByDeletingPathExtension];
    int in = 0, out = 0;
    for (NSString *domain in domains) {
        BOOL skip = NO;
        for (NSString *prefix in skipPrefixes) skip |= [domain hasPrefix:prefix];
        if (skip) continue;
        NSString *file = [domain stringByAppendingPathExtension:@"plist"];
        NSString *localFile = [localPrefs stringByAppendingPathComponent:file], *sharedFile = [sharedPrefs stringByAppendingPathComponent:file];
        NSString *syncedFile = [syncedPrefs stringByAppendingPathComponent:file];
        CFStringRef app = (__bridge CFStringRef)domain;
        CFArrayRef keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        NSDictionary *mine = keys ? CFBridgingRelease(CFPreferencesCopyMultiple(keys, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : @{};
        if (keys) CFRelease(keys);
        NSDictionary *theirs = [NSDictionary dictionaryWithContentsOfFile:sharedFile];   // nil: not shared yet
        NSDictionary *base = [NSDictionary dictionaryWithContentsOfFile:syncedFile] ?: @{};   // what this app last synced
        if ([theirs isEqual:mine]) { if (![base isEqual:mine]) writePlist(mine, syncedFile); continue; }
        if (!theirs && !mine.count) continue;
        BOOL mineChanged = ![mine isEqual:base], theirsChanged = theirs && ![theirs isEqual:base];
        if (theirsChanged && (!mineChanged || later(modified(sharedFile), modified(localFile)))) {
            NSMutableArray<NSString *> *gone = [NSMutableArray array];   // deleted on the other side
            for (NSString *key in mine) if (!theirs[key]) [gone addObject:key];
            CFPreferencesSetMultiple((__bridge CFDictionaryRef)theirs, (__bridge CFArrayRef)gone, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPreferencesAppSynchronize(app);
            writePlist(theirs, syncedFile);
            in++;
        } else if (mineChanged || !theirs) {
            if (!writePlist(mine, sharedFile)) continue;
            writePlist(mine, syncedFile);
            out++;
        }
    }
    return [NSString stringWithFormat:@"settings: %d in, %d out", in, out];
}

// ShackHomePrefsSync runs at a game's end too, after its hooks made mainBundle the game's: gHostID, read at load,
// still names MacShack's own domains to skip.
NSString *ShackHomePrefsSync(void) {
    NSString *group = ShackHomeGroup();
    if (!group) return @"settings: no App Group container";
    NSString *report = ShackPrefsSync([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"],
                                      [group stringByAppendingPathComponent:@"Home/Library/Preferences"],
                                      [NSHomeDirectory() stringByAppendingPathComponent:@"Library/ShackPrefsSync"],   // this app's own
                                      @[@"com.apple.", gHostID ?: @"-", @"com.valvesoftware.", @"org.chromium.", @".GlobalPreferences", @"group."]);
    NSLog(@"[MacShack] %@", report);
    return report;
}

void ShackHomeMirrorLogs(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *to = [docs stringByAppendingPathComponent:@"Logs/Shared"];
    [fm removeItemAtPath:to error:NULL];
    [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *library = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    [fm copyItemAtPath:[library stringByAppendingPathComponent:@"Logs"].stringByResolvingSymlinksInPath toPath:[to stringByAppendingPathComponent:@"Library Logs"] error:NULL];
    NSString *steamLogs = [library stringByAppendingPathComponent:@"Application Support/Steam/logs"].stringByResolvingSymlinksInPath;
    [fm createDirectoryAtPath:[to stringByAppendingPathComponent:@"Steam logs"] withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *name in [fm contentsOfDirectoryAtPath:steamLogs error:NULL])
        if ([name.pathExtension isEqualToString:@"txt"] && ![name hasPrefix:@"cef_log"])   // Chromium's can be huge
            [fm copyItemAtPath:[steamLogs stringByAppendingPathComponent:name] toPath:[to stringByAppendingFormat:@"/Steam logs/%@", name] error:NULL];
}
