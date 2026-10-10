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

static NSString *stamp(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HHmm";
    return [f stringFromDate:NSDate.date];
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
        for (NSString *name in [fm contentsOfDirectoryAtPath:mine error:NULL]) {
            NSString *from = [mine stringByAppendingPathComponent:name], *to = [shared stringByAppendingPathComponent:name];
            if ([[fm attributesOfItemAtPath:from error:NULL].fileType isEqualToString:NSFileTypeSymbolicLink] &&
                [[fm destinationOfSymbolicLinkAtPath:from error:NULL] hasPrefix:home]) {   // already leads into the home
                [fm removeItemAtPath:from error:NULL];
                continue;
            }
            if ([fm fileExistsAtPath:to] || [fm attributesOfItemAtPath:to error:NULL]) {
                NSString *aside = [shared stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (set aside %@)", name, stamp()]];
                if (rename(to.fileSystemRepresentation, aside.fileSystemRepresentation))
                    return [NSString stringWithFormat:@"%@: rename refused (%s) setting aside %@; moved so far: %@", folder, strerror(errno), name,
                            [moved componentsJoinedByString:@", "]];
                [setAside addObject:name];
            }
            if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation))
                return [NSString stringWithFormat:@"%@: rename refused (%s) for %@: left in the container; moved so far: %@", folder, strerror(errno), name,
                        [moved componentsJoinedByString:@", "]];
            [moved addObject:name];
        }
        if (rmdir(mine.fileSystemRepresentation))
            return [NSString stringWithFormat:@"%@: FAILED, folder not empty after the move (%s)", folder, strerror(errno)];
    } else {
        [fm createDirectoryAtPath:mine.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    if (![fm createSymbolicLinkAtPath:mine withDestinationPath:shared error:&e])
        return [NSString stringWithFormat:@"%@: FAILED to link: %@", folder, e.localizedDescription];
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

NSString *ShackPrefsSync(NSString *localPrefs, NSString *sharedPrefs, NSArray<NSString *> *skipPrefixes) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:sharedPrefs withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableSet<NSString *> *domains = [NSMutableSet set];
    for (NSString *folder in @[localPrefs, sharedPrefs])
        for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:NULL])
            if ([name.pathExtension isEqualToString:@"plist"]) [domains addObject:name.stringByDeletingPathExtension];
    int in = 0, out = 0;
    for (NSString *domain in domains) {
        BOOL skip = NO;
        for (NSString *prefix in skipPrefixes) skip |= [domain hasPrefix:prefix];
        if (skip) continue;
        NSString *file = [domain stringByAppendingPathExtension:@"plist"];
        NSString *mine = [localPrefs stringByAppendingPathComponent:file], *theirs = [sharedPrefs stringByAppendingPathComponent:file];
        NSDate *mineDate = modified(mine), *theirsDate = modified(theirs);
        CFStringRef app = (__bridge CFStringRef)domain;
        if (later(theirsDate, mineDate)) {
            NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:theirs];
            if (!values) continue;
            CFPreferencesSetMultiple((__bridge CFDictionaryRef)values, NULL, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFPreferencesAppSynchronize(app);
            in++;
        } else if (later(mineDate, theirsDate)) {
            CFArrayRef keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            NSDictionary *values = keys ? CFBridgingRelease(CFPreferencesCopyMultiple(keys, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : @{};
            if (keys) CFRelease(keys);
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            if (!data || ![data writeToFile:theirs options:NSDataWritingAtomic error:NULL]) continue;
            [fm setAttributes:@{NSFileModificationDate: mineDate} ofItemAtPath:theirs error:NULL];
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
                                      @[@"com.apple.", gHostID ?: @"-", @"com.valvesoftware.", @"org.chromium.", @".GlobalPreferences", @"group."]);
    NSLog(@"[MacShack] %@", report);
    return report;
}
