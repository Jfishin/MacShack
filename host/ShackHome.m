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
