#import "ShackInstaller.h"
#import "ShackSigner.h"
#import "ShackPrep.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <libkern/OSByteOrder.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static id InstallFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ShackInstaller" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}
static NSString *Directory(NSSearchPathDirectory kind) {
#ifdef SHACK_INSTALLER_TEST
    return [[NSProcessInfo.processInfo.environment[@"SHACK_INSTALLER_TEST_ROOT"]
        stringByAppendingPathComponent:kind == NSDocumentDirectory ? @"Documents" : @"Library"] stringByResolvingSymlinksInPath];
#else
    return [NSSearchPathForDirectoriesInDomains(kind, NSUserDomainMask, YES).firstObject stringByResolvingSymlinksInPath];
#endif
}
// Read at load: once a game runs, the identity hooks make mainBundle answer for the game (prepare after play).
static NSBundle *gHostBundle;
__attribute__((constructor)) static void captureHostBundle(void) { gHostBundle = NSBundle.mainBundle; }
// Libraries the host ships for guests (Frameworks/MonoRuntimes).
static NSString *HostFrameworks(void) {
#ifdef SHACK_INSTALLER_TEST
    return NSProcessInfo.processInfo.environment[@"SHACK_INSTALLER_TEST_FRAMEWORKS"];
#else
    return [gHostBundle.resourcePath stringByAppendingPathComponent:@"Frameworks"];
#endif
}
static NSString *GuestRoot(void) { return [Directory(NSLibraryDirectory) stringByAppendingPathComponent:@"Guests"]; }
static NSString *StagingRoot(void) { return [Directory(NSDocumentDirectory) stringByAppendingPathComponent:@"Staging"]; }
static NSString *GamesRoot(void) { return [Directory(NSDocumentDirectory) stringByAppendingPathComponent:@"Games"]; }
static BOOL SafeComponent(id value) {
    return [value isKindOfClass:NSString.class] && [value length] &&
        ![value isEqual:@"."] && ![value isEqual:@".."] &&
        [value rangeOfString:@"/"].location == NSNotFound &&
        [value rangeOfString:@"\0"].location == NSNotFound;
}
static BOOL Inside(NSString *path, NSString *root) {
    return [path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}
static BOOL Regular(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
}
static BOOL MakeDirectory(NSString *path, NSError **error) {
    return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error];
}
static NSString *Digest(NSString *path, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return InstallFail(error, [@"Cannot read " stringByAppendingString:path.lastPathComponent]);
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    unsigned char buffer[65536], hash[CC_SHA256_DIGEST_LENGTH];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof buffer)) > 0) CC_SHA256_Update(&ctx, buffer, (CC_LONG)count);
    close(fd);
    if (count < 0) return InstallFail(error, @"Could not read a file completely.");
    CC_SHA256_Final(hash, &ctx);
    NSMutableString *result = [NSMutableString string];
    for (unsigned i = 0; i < sizeof hash; i++) [result appendFormat:@"%02x", hash[i]];
    return result;
}
static BOOL WritePlist(NSDictionary *value, NSString *path, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    if (![data writeToFile:temporary options:NSDataWritingWithoutOverwriting error:error]) return NO;
    int fd = open(temporary.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    BOOL ok = fd >= 0 && fsync(fd) == 0;
    if (fd >= 0) close(fd);
    if (ok) ok = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        InstallFail(error, @"Could not persist the installation journal.");
    }
    return ok;
}
// Probe only the headers: never read a game's multi-gigabyte data files into memory.
static BOOL IsMachO(NSString *path) {
    uint32_t magic = 0;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    ssize_t n = read(fd, &magic, sizeof magic); close(fd);
    return n == 4 && (magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC ||
        magic == MH_CIGAM || magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
}
// sub -1 accepts any subtype (x86_64 and x86_64h alike).
static BOOL HasSlice(NSString *path, cpu_type_t want, cpu_subtype_t wantSub) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    uint32_t h[3] = {0};
    BOOL yes = NO;
    if (read(fd, h, sizeof h) == sizeof h) {
        if (h[0] == MH_MAGIC_64 || h[0] == MH_MAGIC)   // MH_MAGIC: a thin i386 file (Feral's Batman)
            yes = (cpu_type_t)h[1] == want && (wantSub < 0 || (cpu_subtype_t)(h[2] & ~CPU_SUBTYPE_MASK) == wantSub);
        else if (h[0] == FAT_CIGAM || h[0] == FAT_CIGAM_64 || h[0] == FAT_MAGIC || h[0] == FAT_MAGIC_64) {
            BOOL swap = h[0] == FAT_CIGAM || h[0] == FAT_CIGAM_64;
            BOOL wide = h[0] == FAT_CIGAM_64 || h[0] == FAT_MAGIC_64;
            uint32_t count = swap ? OSSwapInt32(h[1]) : h[1];
            if (count <= 128) for (uint32_t i = 0; i < count; i++) {
                uint32_t arch[4];   // cputype, cpusubtype, then the offset (32 or 64 bits)
                if (pread(fd, arch, sizeof arch, 8 + i * (wide ? 32 : 20)) != sizeof arch) break;
                uint32_t cpu = swap ? OSSwapInt32(arch[0]) : arch[0];
                uint32_t sub = swap ? OSSwapInt32(arch[1]) : arch[1];
                if ((cpu_type_t)cpu != want || (wantSub >= 0 && (cpu_subtype_t)(sub & ~CPU_SUBTYPE_MASK) != wantSub)) continue;
                // The slice must be a Mach-O image: a universal static library (Firebase's .framework/<Name> in Coromon)
                // has an arm64 entry that holds an `ar` archive, which is neither code to sign nor to load.
                uint64_t offset = wide ? ((uint64_t)(swap ? OSSwapInt32(arch[2]) : arch[2]) << 32) | (swap ? OSSwapInt32(arch[3]) : arch[3])
                                       : (swap ? OSSwapInt32(arch[2]) : arch[2]);
                if (wide && !swap) offset = ((uint64_t)arch[3] << 32) | arch[2];
                uint32_t magic = 0;
                if (pread(fd, &magic, sizeof magic, (off_t)offset) == sizeof magic && (magic == MH_MAGIC_64 || magic == MH_MAGIC)) { yes = YES; break; }
            }
        }
    }
    close(fd); return yes;
}
static BOOL HasArm64(NSString *path) { return HasSlice(path, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL); }
static NSString *MonoRevision(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    const unsigned char *bytes = data.bytes;
    NSMutableSet<NSString *> *revisions = [NSMutableSet set];
    for (NSUInteger i = 0; i + 17 <= data.length; i++) {
        if (memcmp(bytes + i, "explicit/", 9)) continue;
        char revision[9] = {0}; BOOL valid = YES;
        for (NSUInteger j = 0; j < 8; j++) {
            unsigned char c = bytes[i + 9 + j];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) { valid = NO; break; }
            revision[j] = c;
        }
        if (valid) [revisions addObject:[NSString stringWithUTF8String:revision]];
    }
    if (revisions.count != 1) return InstallFail(error, @"Cannot identify one exact Unity Mono revision (expected explicit/<8 hex digits>).");
    return revisions.anyObject;
}
static NSString *HostBuild(NSError **error) {
#ifdef SHACK_INSTALLER_TEST
    return @"installer-test";
#else
    static NSString *identity;
    if (!identity) identity = Digest(gHostBundle.executablePath, error);
    return identity;
#endif
}
// NSString's stringByResolvingSymlinksInPath drops /private on some paths and keeps it on others.
static NSString *RealPath(NSString *path) {
    char buffer[PATH_MAX];
    return realpath(path.fileSystemRepresentation, buffer) ? [NSString stringWithUTF8String:buffer] : path;
}
// The directory `to`, written relative to the directory `from` ("Versions/A", "../lib").
static NSString *RelativeDirectory(NSString *from, NSString *to) {
    NSArray *a = from.pathComponents, *b = to.pathComponents;
    NSUInteger common = 0;
    while (common < a.count && common < b.count && [a[common] isEqual:b[common]]) common++;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = common; i < a.count; i++) [parts addObject:@".."];
    for (NSUInteger i = common; i < b.count; i++) [parts addObject:b[i]];
    return [parts componentsJoinedByString:@"/"];
}
static NSString *PrepareAndSign(NSString *input, NSString *unsignedPath, NSString *output,
                                NSString *executableDirectory, BOOL mainExecutable, NSString *loaderPathShift, NSError **error) {
    if (!MakeDirectory(unsignedPath.stringByDeletingLastPathComponent, error) ||
        !MakeDirectory(output.stringByDeletingLastPathComponent, error) ||
        ![NSFileManager.defaultManager copyItemAtPath:input toPath:unsignedPath error:error] ||
        ![ShackPrep prepareBinaryAtPath:unsignedPath outputPath:unsignedPath
            executableDirectory:executableDirectory mainExecutable:mainExecutable loaderPathShift:loaderPathShift error:error] ||
        ![ShackSigner signBinaryAtPath:unsignedPath outputPath:output error:error]) return nil;
    return Digest(output, error);
}
// pending.plist is written before the data rename; current.plist is the sole commit record.
static BOOL Recover(NSString *name, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [GuestRoot() stringByAppendingPathComponent:name];
    NSString *journal = [root stringByAppendingPathComponent:@"pending.plist"];
    if (![fm fileExistsAtPath:journal]) return YES;
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:journal];
    NSString *generation = pending[@"generation"];
    if (!SafeComponent(name) || ![generation isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:generation])
        return InstallFail(error, @"Invalid interrupted installation journal; no files were changed.") != nil;
    NSDictionary *current = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"current.plist"]];
    if (![current[@"generation"] isEqual:generation]) {
        NSString *appName = [name stringByAppendingPathExtension:@"app"];
        NSString *data = [GamesRoot() stringByAppendingPathComponent:appName];
        NSString *source = [StagingRoot() stringByAppendingPathComponent:appName];
        if ([pending[@"movesData"] boolValue] && [fm fileExistsAtPath:data]) {
            if ([fm fileExistsAtPath:source]) return InstallFail(error, @"Interrupted import has both staged and installed data. Preserve both copies and resolve their names before retrying.") != nil;
            if (!MakeDirectory(StagingRoot(), error) || ![fm moveItemAtPath:data toPath:source error:error]) return NO;
        }
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:generation]] &&
            ![fm removeItemAtPath:[root stringByAppendingPathComponent:generation] error:error]) return NO;
    }
    NSString *unsignedRoot = [root stringByAppendingPathComponent:[@".work-" stringByAppendingString:generation]];
    if ([fm fileExistsAtPath:unsignedRoot] && ![fm removeItemAtPath:unsignedRoot error:error]) return NO;
    return [fm removeItemAtPath:journal error:error];
}

// Intel (x86_64-only) games run under AArchX (vendor/AArchX, prep/aarchx): it reads the original Mach-Os from
// Documents/Games as data and runs only code it generates into the JIT pool, so nothing is prepared or signed.
// The manifest marks the game translated; its code root is the data folder itself. arch "i386": a 32-bit-only game,
// which AArchX's m32 runs (prep/aarchx/README.md "32-bit (i386) Mac games").
static NSString *InstallTranslated(NSString *name, NSString *exe, NSString *source, NSString *destination, NSString *root,
                                   NSString *infoPath, BOOL reprepare, NSString *arch, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *infoHash = Digest(infoPath, error);
    if (!infoHash || !MakeDirectory(root, error) || !MakeDirectory(GamesRoot(), error)) return nil;
    if (!reprepare && ![fm moveItemAtPath:source toPath:destination error:error]) return nil;
    // macOS volumes ignore case and iOS's does not: Unity 2019 opens its plugins under NSBundle's builtInPlugInsPath,
    // Contents/PlugIns, through CFBundleCreate, which our case-insensitive file hooks do not reach (Subnautica ships
    // Contents/Plugins). A relative symlink gives the other spelling.
    NSString *plugins = [destination stringByAppendingPathComponent:@"Contents/Plugins"], *plugIns = [destination stringByAppendingPathComponent:@"Contents/PlugIns"];
    BOOL dir = NO;
    if ([fm fileExistsAtPath:plugins isDirectory:&dir] && dir && ![fm fileExistsAtPath:plugIns])
        [fm createSymbolicLinkAtPath:plugIns withDestinationPath:@"Plugins" error:nil];
    NSDictionary *manifest = @{@"version": @1, @"generation": NSUUID.UUID.UUIDString, @"executable": exe,
        @"translate": arch, @"infoHash": infoHash, @"requiresJIT": @YES, @"installedAt": NSDate.date};
    if (!WritePlist(manifest, [root stringByAppendingPathComponent:@"current.plist"], error)) return nil;
    return [NSString stringWithFormat:@"Installed %@: Intel game, runs under %@ translation (AArchX); JIT is enabled at launch.", name, arch];
}

// Prepares and signs every arm64 Mach-O of the bundle at source into root/<new generation> and commits it
// (current.plist). moveData: the data moves to destination at commit (an import), else it stays (a reprepare, a Steam
// game). extra: more manifest entries. Returns the summary, or nil with *error.
static NSString *PrepareGeneration(NSString *name, NSString *exe, NSString *source, NSString *destination, NSString *root,
                                   NSString *infoPath, BOOL moveData, NSDictionary *extra, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *mainRelative = [@"Contents/MacOS" stringByAppendingPathComponent:exe];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *replacements = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *linkShifts = [NSMutableDictionary dictionary];   // linked binary -> directory offset to its real file
    BOOL mono = NO, monoRebuilt = NO;
    __block NSError *scanError = nil;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:source]
        includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey]
        options:0 errorHandler:^BOOL(NSURL *url, NSError *failure) { (void)url; scanError = failure; return NO; }];
    for (NSURL *url in enumerator) {
        NSString *resolved = url.path.stringByResolvingSymlinksInPath;
        if (!Inside(resolved, source)) return InstallFail(error, @"The app contains a symlink outside its bundle. Import stopped without changing the source.");
        NSString *relative = [resolved substringFromIndex:source.length + 1];
        if ([relative.pathComponents indexOfObjectPassingTest:^BOOL(NSString *part, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop; return [part.pathExtension isEqual:@"dSYM"];
        }] != NSNotFound) continue;
        // A symlink to a Mach-O inside the bundle (a framework's Name -> Versions/A/Name, Coromon's CoronaCards) is
        // prepared as a file of its own at the link's path: the load commands, once ShackPrep strips Versions/A, name
        // that path. The same for the top-level binary of a framework whose downloader left the link an empty file
        // (Steam depot symlinks before they were kept): its Versions/A/Name stands in.
        NSString *linked = nil;
        if (!Regular(url.path)) {
            if (!Regular(resolved) || !IsMachO(resolved)) continue;
            NSString *parent = url.path.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
            relative = parent.length > source.length ? [[parent substringFromIndex:source.length + 1] stringByAppendingPathComponent:url.lastPathComponent]
                                                      : url.lastPathComponent;
            linked = resolved;
        } else {
            struct stat st;
            NSString *dir = url.path.stringByDeletingLastPathComponent, *name = url.lastPathComponent;
            if (stat(url.path.fileSystemRepresentation, &st) == 0 && st.st_size == 0 &&
                [dir.lastPathComponent isEqual:[name stringByAppendingString:@".framework"]]) {
                NSString *real = [dir stringByAppendingFormat:@"/Versions/A/%@", name];
                if (Regular(real) && IsMachO(real)) linked = real;
            }
        }
        if (!IsMachO(linked ?: url.path)) continue;
        if (!HasArm64(linked ?: url.path)) { [skipped addObject:relative]; continue; }
        [files addObject:relative];
        if (linked) {
            replacements[relative] = linked;
            linkShifts[relative] = RelativeDirectory(RealPath(url.path.stringByDeletingLastPathComponent), RealPath(linked.stringByDeletingLastPathComponent));
        }
        if ([url.lastPathComponent isEqual:@"libmonobdwgc-2.0.dylib"]) {
            NSString *revision = MonoRevision(url.path, error);
            if (!revision) return nil;
            NSString *replacement = [HostFrameworks() stringByAppendingFormat:@"/MonoRuntimes/%@/libmonobdwgc-2.0.dylib", revision];
            // A revision without a rebuilt runtime keeps the game's own Mono: ShackTrapJIT.c replays its code stores
            // (compiling is slower, the generated code is the same).
            if (Regular(replacement)) {
                if (![MonoRevision(replacement, error) isEqual:revision])
                    return InstallFail(error, @"The bundled Mono replacement has a different revision from the game. Import stopped.");
                replacements[relative] = replacement;
                monoRebuilt = YES;
            }
            mono = YES;
        }
    }
    if (scanError) { if (error) *error = scanError; return nil; }
    if (![files containsObject:mainRelative]) return InstallFail(error, @"The main executable was not found during the bundle scan.");
    NSDictionary *signing = [ShackSigner signingContextWithError:error];
    NSString *hostBuild = signing ? HostBuild(error) : nil;
    if (!signing || !hostBuild) return nil;
    NSString *generation = NSUUID.UUID.UUIDString;
    NSString *work = [root stringByAppendingPathComponent:generation];
    NSString *unsignedRoot = [root stringByAppendingPathComponent:[@".work-" stringByAppendingString:generation]];
    NSString *journal = [root stringByAppendingPathComponent:@"pending.plist"];
    BOOL committed = NO;
    @try {
        if (!MakeDirectory(root, error) || !WritePlist(@{@"generation": generation, @"movesData": @(moveData)}, journal, error) ||
            !MakeDirectory(work, error) || !MakeDirectory(unsignedRoot, error)) return nil;
        [[NSURL fileURLWithPath:root] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        if (!MakeDirectory([work stringByAppendingPathComponent:@"Contents"], error) ||
            ![fm copyItemAtPath:infoPath toPath:[work stringByAppendingPathComponent:@"Contents/Info.plist"] error:error]) return nil;
        NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
        NSMutableDictionary *sourceHashes = [NSMutableDictionary dictionary];
        for (NSString *relative in files) {
            NSString *original = [source stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath;   // Digest does not follow links
            if (!Inside(original, source)) return InstallFail(error, @"The app contains a symlink outside its bundle. Import stopped without changing the source.");
            NSString *sourceHash = Digest(original, error);
            if (!sourceHash) return nil;
            sourceHashes[relative] = sourceHash;
            NSString *input = replacements[relative] ?: original;
            NSString *unsignedPath = [unsignedRoot stringByAppendingPathComponent:relative];
            NSString *output = [work stringByAppendingPathComponent:relative];
            NSError *binaryError = nil;
            NSString *hash = nil;
            // Keep the result and error strong outside the pool so large Mach-O buffers can drain safely.
            @autoreleasepool {
                hash = PrepareAndSign(input, unsignedPath, output,
                    [unsignedRoot stringByAppendingPathComponent:@"Contents/MacOS"],
                    [relative isEqual:mainRelative], linkShifts[relative], &binaryError);
            }
            if (!hash) { if (error) *error = binaryError; return nil; }
            hashes[relative] = hash;
        }
        NSString *infoHash = Digest(infoPath, error);
        if (!infoHash) return nil;
        NSMutableDictionary *manifest = [@{@"version": @1, @"generation": generation, @"executable": exe,
            @"files": hashes, @"sourceFiles": sourceHashes, @"infoHash": infoHash, @"signing": signing, @"hostBuild": hostBuild,
            @"requiresJIT": @(mono), @"installedAt": NSDate.date} mutableCopy];
        [manifest addEntriesFromDictionary:extra ?: @{}];
        if (!MakeDirectory(GamesRoot(), error)) return nil;
        if (moveData && ![fm moveItemAtPath:source toPath:destination error:error]) return nil;
        if (!WritePlist(manifest, [root stringByAppendingPathComponent:@"current.plist"], error)) return nil;
        committed = YES;
        [fm removeItemAtPath:journal error:nil];
        // Old generations are no longer reachable once the new manifest is committed.
        for (NSString *child in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (![child isEqual:generation] && [[NSUUID alloc] initWithUUIDString:child])
                [fm removeItemAtPath:[root stringByAppendingPathComponent:child] error:nil];
        }
        return [NSString stringWithFormat:@"Installed %@: prepared and signed %lu arm64 binaries.%@%@", name,
            (unsigned long)files.count, !mono ? @" No Mono JIT required." : monoRebuilt ? @" Matching dual-mapped Mono installed; JIT is enabled at launch."
                : @" The game's own Mono runs with trapped code writes; JIT is enabled at launch.",
            skipped.count ? [NSString stringWithFormat:@" Skipped %lu Intel/unsupported-architecture optional binaries.", (unsigned long)skipped.count] : @""];
    } @finally {
        [fm removeItemAtPath:unsignedRoot error:nil];
        if (!committed) {
            NSError *recoveryError = nil;
            if ([fm fileExistsAtPath:journal]) {
                if (!Recover(name, &recoveryError) && error) *error = recoveryError;
            } else [fm removeItemAtPath:work error:nil];
        }
    }
}

// The code root of a committed generation (manifest m under root) whose files, sources, host and signing profile are
// unchanged and whose data is at expectedData; else nil with *error.
static NSString *VerifiedCode(NSDictionary *m, NSString *root, NSString *appPath, NSString *expectedData, NSError **error) {
    NSString *generation = m[@"generation"];
    if (![generation isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:generation] ||
        ![m[@"version"] isEqual:@1] || !SafeComponent(m[@"executable"]) || ![m[@"files"] isKindOfClass:NSDictionary.class] ||
        ![m[@"signing"] isKindOfClass:NSDictionary.class] ||
        ![m[@"sourceFiles"] isKindOfClass:NSDictionary.class])
        return InstallFail(error, @"The prepared game manifest is invalid. Prepare the game again.");
    NSDictionary *signing = [ShackSigner signingContextWithError:error];
    if (!signing) return nil;
    if (![m[@"signing"][@"identifier"] isEqual:signing[@"identifier"]] ||
        ![m[@"signing"][@"profileHash"] isEqual:signing[@"profileHash"]] ||
        ![m[@"hostBuild"] isEqual:HostBuild(error)])
        return InstallFail(error, @"MacShack or its development profile changed after this game was prepared. Its code must be prepared and signed again.");
    if (![appPath.stringByResolvingSymlinksInPath isEqual:expectedData.stringByStandardizingPath] ||
        ![m[@"infoHash"] isEqual:Digest([appPath stringByAppendingPathComponent:@"Contents/Info.plist"], error)])
        return InstallFail(error, @"The installed game metadata changed or its data folder is missing.");
    NSString *code = [root stringByAppendingPathComponent:generation];
    NSDictionary *hashes = m[@"files"];
    if (!hashes[[@"Contents/MacOS" stringByAppendingPathComponent:m[@"executable"]]])
        return InstallFail(error, @"The prepared main executable is absent from the manifest.");
    for (NSString *relative in hashes) {
        if (![relative isKindOfClass:NSString.class] || [relative hasPrefix:@"/"] ||
            [relative.pathComponents containsObject:@".."] || !Inside([code stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath, code) ||
            ![hashes[relative] isEqual:Digest([code stringByAppendingPathComponent:relative], error)])
            return InstallFail(error, @"Prepared code is missing or changed. Prepare the game again before launching.");
    }
    for (NSString *relative in m[@"sourceFiles"]) {
        if (![relative isKindOfClass:NSString.class] || [relative hasPrefix:@"/"] ||
            [relative.pathComponents containsObject:@".."] ||
            !Inside([appPath stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath, expectedData) ||
            ![m[@"sourceFiles"][relative] isEqual:Digest([appPath stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath, error)])
            return InstallFail(error, @"The game's original code changed. Prepare the game again before launching.");
    }
    return code;
}

@implementation ShackInstaller
+ (BOOL)recoverInterruptedInstallsWithError:(NSError **)error {
    @synchronized(self) {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:GuestRoot()]) return YES;
        NSArray *names = [fm contentsOfDirectoryAtPath:GuestRoot() error:error];
        if (!names) return NO;
        for (NSString *name in names) if (!Recover(name, error)) return NO;
        return YES;
    }
}

+ (NSString *)installAppAtPath:(NSString *)appPath error:(NSError **)error {
    @synchronized(self) {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![self recoverInterruptedInstallsWithError:error]) return nil;
        appPath = appPath.stringByStandardizingPath;
        // Canonicalize the container prefix while still rejecting a symlink for the app itself.
        NSString *parent = appPath.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
        appPath = [parent stringByAppendingPathComponent:appPath.lastPathComponent];
        NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
        NSString *installedPath = [GamesRoot() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
        BOOL reprepare = [appPath isEqual:installedPath];
        NSString *source = reprepare ? installedPath : [StagingRoot() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
        if (!SafeComponent(name) || ![appPath isEqual:source.stringByStandardizingPath] ||
            ![appPath.stringByResolvingSymlinksInPath isEqual:appPath])
            return InstallFail(error, @"Prepare a real .app directory directly inside MacShack/Staging or MacShack/Games.");
        BOOL directory = NO;
        if (![fm fileExistsAtPath:source isDirectory:&directory] || !directory)
            return InstallFail(error, @"The staged .app directory is missing.");
        NSString *destination = [GamesRoot() stringByAppendingPathComponent:source.lastPathComponent];
        NSString *root = [GuestRoot() stringByAppendingPathComponent:name];
        if (!reprepare && ([fm fileExistsAtPath:destination] || [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"current.plist"]]))
            return InstallFail(error, @"A game with this name is already installed. This importer does not replace existing game data.");
        NSString *infoPath = [source stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        NSString *exe = info[@"CFBundleExecutable"];
        if (!SafeComponent(exe) || !Regular(infoPath) || !Inside(infoPath.stringByResolvingSymlinksInPath, source))
            return InstallFail(error, @"The app needs a valid Contents/Info.plist with a safe CFBundleExecutable filename.");
        NSString *mainRelative = [@"Contents/MacOS" stringByAppendingPathComponent:exe];
        NSString *main = [source stringByAppendingPathComponent:mainRelative];
        if (Regular(main) && Inside(main.stringByResolvingSymlinksInPath, source) && !HasArm64(main) &&
            HasSlice(main, CPU_TYPE_X86_64, -1))
            return InstallTranslated(name, exe, source, destination, root, infoPath, reprepare, @"x86_64", error);
        if (Regular(main) && Inside(main.stringByResolvingSymlinksInPath, source) && !HasArm64(main) &&
            HasSlice(main, CPU_TYPE_I386, -1))
            return InstallTranslated(name, exe, source, destination, root, infoPath, reprepare, @"i386", error);
        if (!Regular(main) || !Inside(main.stringByResolvingSymlinksInPath, source) || !HasArm64(main))
            return InstallFail(error, @"The main executable must be a regular arm64, x86_64 or i386 Mach-O file. arm64e-only games cannot run.");
        return PrepareGeneration(name, exe, source, destination, root, infoPath, !reprepare, nil, error);
    }
}

+ (NSString *)preparedCodeRootForAppPath:(NSString *)appPath error:(NSError **)error {
    @synchronized(self) {
        NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
        if (!SafeComponent(name)) return InstallFail(error, @"Invalid game name.");
        if (!Recover(name, error)) return nil;
        NSString *root = [GuestRoot() stringByAppendingPathComponent:name];
        NSString *path = [root stringByAppendingPathComponent:@"current.plist"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([m[@"translate"] isEqual:@"x86_64"] || [m[@"translate"] isEqual:@"i386"]) {
            NSString *expected = [GamesRoot() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
            if (!SafeComponent(m[@"executable"]) || ![appPath.stringByResolvingSymlinksInPath isEqual:expected.stringByStandardizingPath] ||
                ![m[@"infoHash"] isEqual:Digest([appPath stringByAppendingPathComponent:@"Contents/Info.plist"], error)])
                return InstallFail(error, @"The installed game metadata changed or its data folder is missing.");
            return appPath;
        }
        return VerifiedCode(m, root, appPath, [GamesRoot() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]], error);
    }
}
+ (NSString *)steamGameCodeRootForAppPath:(NSString *)appPath error:(NSError **)error {
    @synchronized(self) {
        appPath = appPath.stringByStandardizingPath;
        NSString *name = [@"Steam." stringByAppendingString:appPath.lastPathComponent.stringByDeletingPathExtension];
        if (!SafeComponent(name)) return InstallFail(error, @"Invalid game name.");
        if (!Recover(name, error)) return nil;
        NSString *root = [GuestRoot() stringByAppendingPathComponent:name];
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSString *exe = [NSDictionary dictionaryWithContentsOfFile:infoPath][@"CFBundleExecutable"];
        NSString *main = [appPath stringByAppendingFormat:@"/Contents/MacOS/%@", exe];
        if (!SafeComponent(exe) || !Regular(infoPath) || !Inside(infoPath.stringByResolvingSymlinksInPath, appPath.stringByResolvingSymlinksInPath))
            return InstallFail(error, @"The game needs a valid Contents/Info.plist with a safe CFBundleExecutable filename.");
        if (!Regular(main) || !Inside(main.stringByResolvingSymlinksInPath, appPath.stringByResolvingSymlinksInPath))
            return InstallFail(error, @"The game's main executable is missing.");
        // An Intel game runs from Steam's own files under AArchX, as an imported one does (InstallTranslated): its code
        // root is its data. Done every launch (cheap, and idempotent).
        NSString *arch = HasArm64(main) ? nil : HasSlice(main, CPU_TYPE_X86_64, -1) ? @"x86_64" : HasSlice(main, CPU_TYPE_I386, -1) ? @"i386" : nil;
        if (arch) {
            NSString *summary = InstallTranslated(name, exe, appPath, appPath, root, infoPath, YES, arch, error);
            if (summary) NSLog(@"[MacShack] %@", summary);
            return summary ? appPath : nil;
        }
        if (!HasArm64(main)) return InstallFail(error, @"The main executable must be an arm64, x86_64 or i386 Mach-O file.");
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"current.plist"]];
        NSError *stale = nil;
        NSString *code = [m[@"dataPath"] isEqual:appPath] ? VerifiedCode(m, root, appPath, appPath, &stale) : nil;
        if (code) return code;
        if (stale) NSLog(@"[MacShack] %@: preparing again (%@)", name, stale.localizedDescription);
        NSString *summary = PrepareGeneration(name, exe, appPath, nil, root, infoPath, NO, @{@"dataPath": appPath}, error);
        if (!summary) return nil;
        NSLog(@"[MacShack] %@", summary);
        m = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"current.plist"]];
        return VerifiedCode(m, root, appPath, appPath, error);
    }
}

+ (NSDictionary *)steamGameManifestForAppPath:(NSString *)appPath {
    NSString *name = [@"Steam." stringByAppendingString:appPath.lastPathComponent.stringByDeletingPathExtension];
    return SafeComponent(name) ? [NSDictionary dictionaryWithContentsOfFile:[[GuestRoot() stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"current.plist"]] : nil;
}

+ (BOOL)translatesAtAppPath:(NSString *)appPath {
    NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
    if (!SafeComponent(name)) return NO;
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[[GuestRoot() stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"current.plist"]];
    return [manifest[@"translate"] isEqual:@"x86_64"] || [manifest[@"translate"] isEqual:@"i386"];
}

+ (BOOL)requiresJITAtAppPath:(NSString *)appPath {
    NSString *name = appPath.lastPathComponent.stringByDeletingPathExtension;
    if (!SafeComponent(name)) return NO;
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[[GuestRoot() stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"current.plist"]];
    if (manifest) return [manifest[@"requiresJIT"] boolValue];
    for (NSString *relative in @[@"Contents/Frameworks/libmonobdwgc-2.0.dylib", @"Contents/MonoBleedingEdge/EmbedRuntime/libmonobdwgc-2.0.dylib"])
        if ([NSFileManager.defaultManager fileExistsAtPath:[appPath stringByAppendingPathComponent:relative]]) return YES;
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtPath:appPath];
    for (NSString *relative in files) if ([relative.lastPathComponent isEqual:@"libmonobdwgc-2.0.dylib"]) return YES;
    return NO;
}
@end
