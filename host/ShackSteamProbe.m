#import "ShackSteamProbe.h"
#import "ShackPrep.h"
#import "ShackSigner.h"
#import "ShackSteamPlay.h"
#import <dlfcn.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>

// Steam's own copy (the macOS client, as Steam lays it out under ~) and the prepared, signed mirror of its code.
static NSString *SteamBundle(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam/Steam.AppBundle/Steam"];
}
static NSString *GuestBundle(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Guests/SteamClient/Steam"];
}

// Every library the Steam client imports something iOS and the shims lack from, and the ones iOS does not have at all,
// go to libShackSteamClient (shims/SteamClient, generated from prep/steam-onehost/ios-link-gaps.txt), which re-exports
// the usual shim or iOS framework and adds those symbols. Only the Steam client is prepared with this map.
// prep/steam-onehost/check_gaps.py checks the same map on the Mac.
static NSDictionary<NSString *, NSString *> *SteamLinkMap(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"AppKit", @"Cocoa", @"Foundation", @"Quartz", @"QuartzCore", @"Carbon", @"CoreServices",
                             @"CoreGraphics", @"ApplicationServices", @"CoreVideo", @"Metal", @"IOKit", @"ForceFeedback",
                             @"Security", @"SecurityFoundation", @"libSystem", @"CFNetwork", @"OpenGL", @"CoreText",
                             @"CoreFoundation", @"VideoToolbox", @"AuthenticationServices", @"SafariServices",
                             @"DiskArbitration", @"OpenDirectory", @"IOBluetooth", @"CoreWLAN", @"SecurityInterface",
                             @"ServiceManagement", @"/usr/lib/libcups.2.dylib", @"/usr/lib/libpmenergy.dylib",
                             @"/usr/lib/libpmsample.dylib"])
        map[name] = @"SteamClient";
    return map;
}

static FILE *gLog;
static void Say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Say(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    if (gLog) {   // the load probe's log; a helper-files prepare at launch only NSLogs
        fprintf(gLog, "%s %s\n", NSDate.date.description.UTF8String, line.UTF8String);
        fflush(gLog);   // a crash in an image's initializers must not lose the line naming it
    }
    NSLog(@"[SteamProbe] %@", line);
}

// The Mach-O file type of a file's arm64 slice, or 0 (not Mach-O, or no arm64).
static uint32_t Arm64Type(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const uint8_t *b = d.bytes;
    if (d.length < 32) return 0;
    uint32_t magic = *(const uint32_t *)b;
    if (magic == MH_MAGIC_64)
        return *(const uint32_t *)(b + 4) == CPU_TYPE_ARM64 ? *(const uint32_t *)(b + 12) : 0;
    if (magic != FAT_CIGAM) return 0;   // the universal header is big-endian
    uint32_t n = OSSwapBigToHostInt32(*(const uint32_t *)(b + 4));
    for (uint32_t i = 0; i < n && 8 + (i + 1) * sizeof(struct fat_arch) <= d.length; i++) {
        const struct fat_arch *a = (const void *)(b + 8 + i * sizeof(struct fat_arch));
        uint32_t off = OSSwapBigToHostInt32(a->offset);
        if ((cpu_type_t)OSSwapBigToHostInt32(a->cputype) == CPU_TYPE_ARM64 && off + 16 <= d.length)
            return *(const uint32_t *)(b + off + 12);
    }
    return 0;
}

NSDictionary<NSString *, NSString *> *ShackSteamHelperFiles(void) {
    return @{@"Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper": @"Contents/MacOS/Steam Helper.helper",
             @"Contents/MacOS/libtier0_s.dylib": @"Contents/MacOS/libtier0_h.dylib",
             @"Contents/MacOS/libvstdlib_s.dylib": @"Contents/MacOS/libvstdlib_h.dylib",
             @"Contents/MacOS/libSDL3.dylib": @"Contents/MacOS/libSDLh.dylib",
             // Its own Steam client API (SteamClient.Input's controller messages come through it): steam_osx's steamclient
             // is the server end of Steam's IPC, so the helper connects with a copy of its own, as a separate process would.
             @"Contents/MacOS/steamclient.dylib": @"Contents/MacOS/steamclient_h.dylib",
             @"Contents/MacOS/libaudio.dylib": @"Contents/MacOS/libaudih.dylib"};
}

// A game Steam starts gets its own Steam client API the same way (libsteam_api loads steamclient_g, which connects to
// steam_osx's as a separate game process would).
NSDictionary<NSString *, NSString *> *ShackSteamGameFiles(void) {
    return @{@"Contents/MacOS/libtier0_s.dylib": @"Contents/MacOS/libtier0_g.dylib",
             @"Contents/MacOS/libvstdlib_s.dylib": @"Contents/MacOS/libvstdlib_g.dylib",
             @"Contents/MacOS/steamclient.dylib": @"Contents/MacOS/steamclient_g.dylib",
             @"Contents/MacOS/libaudio.dylib": @"Contents/MacOS/libaudig.dylib"};
}

// Prepares and signs a private image set (Steam Helper's, letter h; a game's, g) into the code folder (all, or only
// those not there yet); returns how many failed. Each input is copied to its output place in the work tree first, so
// its @executable_path links resolve from where it will live.
static NSUInteger PrepareHelperFiles(NSDictionary<NSString *, NSString *> *privateFiles, char letter, NSString *source, NSString *guest,
                                     NSString *work, BOOL onlyMissing, NSMutableArray<NSString *> *prepared) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *helperMap = [SteamLinkMap() mutableCopy];
    [helperMap addEntriesFromDictionary:@{@"@loader_path/libtier0_s.dylib": [NSString stringWithFormat:@"@loader_path/libtier0_%c.dylib", letter],
                                          @"@loader_path/libvstdlib_s.dylib": [NSString stringWithFormat:@"@loader_path/libvstdlib_%c.dylib", letter],
                                          @"@loader_path/libSDL3.dylib": [NSString stringWithFormat:@"@loader_path/libSDL%c.dylib", letter],
                                          @"@loader_path/libaudio.dylib": [NSString stringWithFormat:@"@loader_path/libaudi%c.dylib", letter]}];
    NSString *workExeDir = [work stringByAppendingPathComponent:@"Contents/MacOS"];
    NSUInteger failed = 0;
    for (NSString *from in privateFiles) {
        NSString *to = privateFiles[from], *unsignedPath = [work stringByAppendingPathComponent:to];
        if (onlyMissing && [fm fileExistsAtPath:[guest stringByAppendingPathComponent:to]]) continue;
        NSError *error = nil;
        [fm createDirectoryAtPath:unsignedPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:unsignedPath error:nil];
        BOOL ok = [fm copyItemAtPath:[source stringByAppendingPathComponent:from] toPath:unsignedPath error:&error] &&
            [ShackPrep prepareBinaryAtPath:unsignedPath outputPath:unsignedPath executableDirectory:workExeDir
                            mainExecutable:[to hasSuffix:@".helper"] loaderPathShift:nil linkMap:helperMap error:&error] &&
            [ShackSigner signBinaryAtPath:unsignedPath outputPath:[guest stringByAppendingPathComponent:to] error:&error];
        if (ok) [prepared addObject:to];
        else { failed++; Say(@"PREPARE FAIL %@: %@", to, error.localizedDescription); }
    }
    return failed;
}

// Steam's own steamclient (the server end steam_osx runs), prepared again from Steam's copy: with Steam Play's patches
// (ShackSteamPlay.m) while Windows games are on, as Valve ships it otherwise. Signed beside the old copy and renamed
// over it: a new file (the signer wants a fresh destination; iOS wants a new inode).
static NSString *const kSteamClient = @"Contents/MacOS/steamclient.dylib";
static BOOL PrepareSteamClient(NSString *source, NSString *guest, NSString *work, BOOL steamPlay, NSError **error) {
    NSString *unsignedPath = [work stringByAppendingPathComponent:kSteamClient], *output = [guest stringByAppendingPathComponent:kSteamClient];
    for (NSString *dir in @[unsignedPath.stringByDeletingLastPathComponent, output.stringByDeletingLastPathComponent])
        if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (![ShackPrep prepareBinaryAtPath:[source stringByAppendingPathComponent:kSteamClient] outputPath:unsignedPath
                    executableDirectory:[source stringByAppendingPathComponent:@"Contents/MacOS"] mainExecutable:NO
                        loaderPathShift:nil linkMap:SteamLinkMap() error:error]) return NO;
    if (steamPlay) Say(@"Steam Play: %@", ShackSteamPlayPatch(unsignedPath));
    NSString *fresh = [output stringByAppendingString:@".new"];
    [NSFileManager.defaultManager removeItemAtPath:fresh error:nil];
    if (![ShackSigner signBinaryAtPath:unsignedPath outputPath:fresh error:error]) return NO;
    if (!rename(fresh.fileSystemRepresentation, output.fileSystemRepresentation)) return YES;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
}

// ponytail: synchronous on the launching (main) thread, once per new private file (a steamclient copy: seconds).
void ShackSteamPrepareHelperFiles(BOOL steamPlay) {
    NSString *work = [GuestBundle() stringByAppendingString:@".helperwork"];
    NSMutableArray *prepared = [NSMutableArray array];
    if (![ShackSigner signingContextWithError:nil]) return;
    NSUInteger failed = PrepareHelperFiles(ShackSteamHelperFiles(), 'h', SteamBundle(), GuestBundle(), work, YES, prepared) +
                        PrepareHelperFiles(ShackSteamGameFiles(), 'g', SteamBundle(), GuestBundle(), work, YES, prepared);
    // steamclient as Steam Play wants it: patched while Windows games are on, Valve's own otherwise.
    NSString *state = ShackSteamPlayCheck([GuestBundle() stringByAppendingPathComponent:kSteamClient]);
    if (steamPlay ? [state hasPrefix:@"would patch"] : [state isEqualToString:@"already patched"]) {
        NSError *error = nil;
        if (PrepareSteamClient(SteamBundle(), GuestBundle(), work, steamPlay, &error)) [prepared addObject:kSteamClient];
        else { failed++; NSLog(@"[MacShack] steamclient not prepared %@ Steam Play: %@", steamPlay ? @"for" : @"without", error.localizedDescription); }
    } else NSLog(@"[MacShack] Steam Play %@: steamclient %@", steamPlay ? @"on" : @"off", state);
    [NSFileManager.defaultManager removeItemAtPath:work error:nil];
    if (prepared.count || failed) NSLog(@"[MacShack] Steam Helper files prepared: %@, %lu failed", prepared, (unsigned long)failed);
}

NSArray<NSString *> *ShackSteamPrepare(NSString *source, NSString *guest, NSMutableArray<NSString *> *prepared,
                                       void (^progress)(NSUInteger done, NSUInteger total)) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *work = [guest stringByAppendingString:@".work"];   // prepared, not yet signed
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    if (!prepared) prepared = [NSMutableArray array];
    [fm removeItemAtPath:guest error:nil];
    [fm removeItemAtPath:work error:nil];
    // The three programs Steam starts become dylibs run in-process; any other executable (updaters, crash reporters,
    // steamsysinfo) is never started on iOS and is left out.
    NSSet *programs = [NSSet setWithArray:@[@"Contents/MacOS/steam_osx", @"Contents/MacOS/ipcserver"]];
    // @executable_path is steam_osx's folder for every image, the Steam Helper included (its framework links resolve
    // through Contents/Frameworks, as Steam's own copy does). ShackPrep relates it to the input's folder: same tree.
    NSString *exeDir = [source stringByAppendingPathComponent:@"Contents/MacOS"];
    // The walk first: symlinks copied as they are, images listed (progress needs the total).
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSUInteger skipped = 0;
    NSDirectoryEnumerator<NSString *> *walk = [fm enumeratorAtPath:source];
    for (NSString *relative in walk) {
        NSString *path = [source stringByAppendingPathComponent:relative];
        NSDictionary *attrs = walk.fileAttributes;
        if ([attrs.fileType isEqual:NSFileTypeSymbolicLink]) {   // framework Versions/Current and the like, as they are
            NSString *target = [fm destinationOfSymbolicLinkAtPath:path error:nil];
            for (NSString *root in @[work, guest]) {
                NSString *link = [root stringByAppendingPathComponent:relative];
                [fm createDirectoryAtPath:link.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [fm createSymbolicLinkAtPath:link withDestinationPath:target error:nil];
            }
            continue;
        }
        if (![attrs.fileType isEqual:NSFileTypeRegular] || attrs.fileSize < 4096) continue;
        uint32_t type = Arm64Type(path);
        if (!type) continue;
        if (type == MH_EXECUTE && ![programs containsObject:relative]) { skipped++; continue; }
        [images addObject:relative];
    }
    NSUInteger total = images.count + ShackSteamHelperFiles().count + ShackSteamGameFiles().count, done = 0;
    for (NSString *relative in images) {
        NSString *unsignedPath = [work stringByAppendingPathComponent:relative];
        NSString *output = [guest stringByAppendingPathComponent:relative];
        NSError *error = nil;
        @autoreleasepool {
            BOOL ok = [fm createDirectoryAtPath:unsignedPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] &&
                [fm createDirectoryAtPath:output.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] &&
                [ShackPrep prepareBinaryAtPath:[source stringByAppendingPathComponent:relative] outputPath:unsignedPath executableDirectory:exeDir
                                mainExecutable:[programs containsObject:relative] loaderPathShift:nil linkMap:SteamLinkMap() error:&error] &&
                [ShackSigner signBinaryAtPath:unsignedPath outputPath:output error:&error];
            if (ok) [prepared addObject:relative];
            else {
                [failures addObject:[NSString stringWithFormat:@"%@: %@", relative, error.localizedDescription]];
                Say(@"PREPARE FAIL %@: %@", relative, error.localizedDescription);
            }
        }
        if (progress) progress(++done, total);
    }
    // Steam Helper runs in-process with private copies of tier0, vstdlib and SDL3, as its own process would (a shared
    // tier0 has one "main thread" and one command line, a shared SDL3 one event queue): MacOS/Steam Helper.helper and
    // lib*_h.dylib beside steam_osx, links and ids renamed (same-length names). A game Steam starts gets the _g set.
    NSUInteger imageFailures = failures.count;
    NSUInteger failed = PrepareHelperFiles(ShackSteamHelperFiles(), 'h', source, guest, work, NO, prepared) +
                        PrepareHelperFiles(ShackSteamGameFiles(), 'g', source, guest, work, NO, prepared);
    if (failed) [failures addObject:[NSString stringWithFormat:@"%lu private Steam Helper or game images (PREPARE FAIL in the log)", (unsigned long)failed]];
    if (progress) progress(total, total);
    [fm removeItemAtPath:work error:nil];
    Say(@"prepared and signed %lu images, %lu failed, %lu other programs left out", (unsigned long)prepared.count,
        (unsigned long)(imageFailures + failed), (unsigned long)skipped);
    return failures;
}

void ShackSteamLoadProbe(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *logs = [docs stringByAppendingPathComponent:@"Logs"];
    [fm createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    gLog = fopen([logs stringByAppendingPathComponent:@"steam-load.log"].fileSystemRepresentation, "w");
    NSString *source = SteamBundle(), *guest = GuestBundle();
    Say(@"Steam client load probe: %@", source);
    if (![fm fileExistsAtPath:[source stringByAppendingPathComponent:@"Contents/MacOS/steam_osx"]]) { Say(@"no Steam client copied here"); return; }
    if (![ShackSigner signingContextWithError:nil]) { Say(@"no signing identity imported"); return; }
    NSMutableArray<NSString *> *prepared = [NSMutableArray array];
    ShackSteamPrepare(source, guest, prepared, nil);
    // Libraries first, the three programs last (their initializers start the most); each line is flushed before the
    // load, so a crash names its image.
    NSSet *programs = [NSSet setWithArray:@[@"Contents/MacOS/steam_osx", @"Contents/MacOS/ipcserver"]];
    [prepared sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL pa = [programs containsObject:a] || [a hasSuffix:@".helper"], pb = [programs containsObject:b] || [b hasSuffix:@".helper"];
        return pa != pb ? (pa ? NSOrderedDescending : NSOrderedAscending) : [a compare:b];
    }];
    NSUInteger loaded = 0;
    for (NSString *relative in prepared) {
        Say(@"load %@", relative);
        void *h = dlopen([guest stringByAppendingPathComponent:relative].fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (h) { loaded++; Say(@"  ok"); }
        else Say(@"  LOAD FAIL %s", dlerror());
    }
    Say(@"done: %lu of %lu images load", (unsigned long)loaded, (unsigned long)prepared.count);
}

// iOS loads a library from outside an app when its code-signing identifier is that app's bundle id: MacShack Play gets
// its own signature of the prepared images (the code folder's, re-signed), each published as a new file.
NSString *ShackSteamPreparePlayFiles(NSURL *group, NSString *identifier) {
    if (!group) return @"no App Group container";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *files = [ShackSteamGameFiles().allValues arrayByAddingObjectsFromArray:@[
        @"Contents/MacOS/crashhandler.dylib", @"Contents/MacOS/Frameworks/Breakpad.framework/Versions/A/Breakpad",
        @"Contents/MacOS/Frameworks/Breakpad.framework/Versions/A/Resources/breakpadUtilities.dylib"]];
    NSString *root = [group.path stringByAppendingPathComponent:@"SteamClient"];
    NSMutableArray<NSString *> *signedNow = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *from = [GuestBundle() stringByAppendingPathComponent:file], *to = [root stringByAppendingPathComponent:file];
        NSDate *made = [fm attributesOfItemAtPath:from error:nil].fileModificationDate, *copied = [fm attributesOfItemAtPath:to error:nil].fileModificationDate;
        if (!made) { [failed addObject:[file.lastPathComponent stringByAppendingString:@" (not prepared)"]]; continue; }
        if (copied && [copied compare:made] != NSOrderedAscending) continue;   // signed for Play since it was prepared
        NSString *fresh = [to stringByAppendingString:@".new"];
        NSError *error = nil;
        [fm removeItemAtPath:fresh error:nil];
        BOOL ok = [fm createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] &&
                  [ShackSigner signBinaryAtPath:from outputPath:fresh identifier:identifier error:&error] &&
                  !rename(fresh.fileSystemRepresentation, to.fileSystemRepresentation);
        if (ok) [signedNow addObject:file.lastPathComponent];
        else [failed addObject:[NSString stringWithFormat:@"%@ (%@)", file.lastPathComponent, error.localizedDescription ?: @(strerror(errno))]];
    }
    // Breakpad's framework links, as Steam has them: the prepared crashhandler loads Breakpad.framework/Breakpad.
    NSString *framework = [root stringByAppendingPathComponent:@"Contents/MacOS/Frameworks/Breakpad.framework"];
    for (NSArray<NSString *> *link in @[@[@"Versions/Current", @"A"], @[@"Breakpad", @"Versions/Current/Breakpad"]])
        if (![fm destinationOfSymbolicLinkAtPath:[framework stringByAppendingPathComponent:link[0]] error:nil])
            [fm createSymbolicLinkAtPath:[framework stringByAppendingPathComponent:link[0]] withDestinationPath:link[1] error:nil];
    return [NSString stringWithFormat:@"Play's Steam images in %@: signed as %@: %@; failed: %@", root, identifier,
            signedNow.count ? [signedNow componentsJoinedByString:@", "] : @"none needed", failed.count ? [failed componentsJoinedByString:@", "] : @"none"];
}
