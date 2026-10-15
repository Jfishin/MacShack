#import "ShackLoader.h"
#import "ShackInstaller.h"
#import "ShackPlay.h"
#import "ShackHome.h"

// MacShack Play runs Mac games too: a game started from MacShack runs in a fresh Play process each time, so games can
// follow one another without restarting MacShack. This is the first path in: `--play-mac <Name>` for an installed
// Local Games game. ponytail: the data is copied into the App Group per game; the one-time move to a shared home
// replaces the copy, and Steam and Local Games' own Play buttons replace the flag.

static void say(NSString *line) {   // Documents/Logs/play-mac-runs.txt, appended, one line per event
    NSLog(@"[MacShack] play-mac: %@", line);
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs/play-mac-runs.txt"];
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone
                                                                                        formatOptions:NSISO8601DateFormatWithInternetDateTime], line];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) { [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; return; }
    [file seekToEndOfFile];
    [file writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

void ShackPlayMacRun(NSString *name, NSUInteger seconds, NSUInteger runs) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *group = [fm containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(ShackPlayHostBundleID())].path;
    NSString *app = [docs stringByAppendingFormat:@"/Games/%@.app", name];
    if (!group) { say(@"no App Group container"); return; }
    if (![fm fileExistsAtPath:app]) { say([@"no installed game at " stringByAppendingString:app]); return; }
    // The last run's report (MacShack's lines, then Play's) stays as play-mac-prev.txt.
    NSString *report = [docs stringByAppendingPathComponent:@"Logs/play-mac.txt"], *previous = [docs stringByAppendingPathComponent:@"Logs/play-mac-prev.txt"];
    [fm removeItemAtPath:previous error:NULL];
    [fm moveItemAtPath:report toPath:previous error:NULL];
    NSString *games = [group stringByAppendingPathComponent:@"Games"], *shared = [games stringByAppendingFormat:@"/%@.app", name];
    NSString *args = [app.stringByDeletingPathExtension stringByAppendingPathExtension:@"args"];
    NSString *sharedArgs = [shared.stringByDeletingPathExtension stringByAppendingPathExtension:@"args"];
    NSError *error = nil;
    [fm createDirectoryAtPath:games withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *dataReport = ShackShareGameData([docs stringByAppendingPathComponent:@"Games"], games);   // BMAAData beside Batman
    if (dataReport.length) say(dataReport);
    if (![fm fileExistsAtPath:shared] && ![fm copyItemAtPath:app toPath:shared error:&error]) { say([@"copy into the App Group failed: " stringByAppendingString:error.localizedDescription]); return; }
    if ([fm fileExistsAtPath:args]) { [fm removeItemAtPath:sharedArgs error:NULL]; [fm copyItemAtPath:args toPath:sharedArgs error:NULL]; }
    NSString *arch = [ShackInstaller translationForAppPath:shared];   // x86_64 or i386: AArchX in Play, nothing prepared
    NSString *code = [ShackInstaller playCodeRootForAppPath:shared guests:[group stringByAppendingPathComponent:@"Guests"]
                                                identifier:[ShackPlayHostBundleID() stringByAppendingString:@".play"] steam:NO
                                                translated:arch != nil error:&error];
    if (!code) { say([@"not prepared for Play: " stringByAppendingString:error.localizedDescription]); return; }
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[group stringByAppendingFormat:@"/Guests/Play.%@/current.plist", name]];
    NSMutableDictionary *launch = [@{@"app": shared, @"code": code, @"logs": [group stringByAppendingPathComponent:@"Logs"], @"argsFile": sharedArgs,
        @"translate": @(arch != nil), @"requiresJIT": @([manifest[@"requiresJIT"] boolValue] || arch),
        @"fpsCap": @(ShackGameFrameCap(name, arch != nil)), @"renderScale": @(ShackGameRenderScale(name, arch != nil)), @"swapMB": @0} mutableCopy];
    NSString *displaySize = [NSUserDefaults.standardUserDefaults stringForKey:[@"displaySize." stringByAppendingString:name]];
    if (displaySize.length) launch[@"displaySize"] = displaySize;
    NSString *notes = [group stringByAppendingPathComponent:@"Launch"];
    [fm createDirectoryAtPath:notes withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![launch writeToFile:[notes stringByAppendingPathComponent:@"current.plist"] atomically:YES]) { say(@"launch note not written"); return; }
    NSString *exe = [NSDictionary dictionaryWithContentsOfFile:[shared stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleExecutable"];
    say([NSString stringWithFormat:@"%@: code %@, starting MacShack Play (%lu run%@ left)", name, code, (unsigned long)runs, runs == 1 ? @"" : @"s"]);
    NSDictionary *query = seconds ? @{@"name": name, @"seconds": [NSString stringWithFormat:@"%lu", (unsigned long)seconds]} : @{@"name": name};
    ShackPlayStart(@"mac", query, ^(int status) {
        // The game's log into MacShack's Documents/Logs, where AutoConfig and devicectl read it.
        NSString *log = [group stringByAppendingFormat:@"/Logs/%@.log", exe], *mine = [docs stringByAppendingFormat:@"/Logs/%@.log", exe];
        [fm removeItemAtPath:mine error:NULL];
        [fm copyItemAtPath:log toPath:mine error:NULL];
        ShackHomeMirrorLogs();
        say([NSString stringWithFormat:@"%@ ended (%d)", name, status]);
        if (runs <= 1) return;
        // ponytail: 5 s for MacShack to be in front again and merge Play's report; ShackPlayStart then waits for the
        // last Play process itself.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            ShackPlayMacRun(name, seconds, runs - 1);
        });
    });
}
