#import "ShackPrep.h"
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach/machine.h>
#import <libkern/OSByteOrder.h>

static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ShackPrep" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static uint32_t U32(const void *p) { uint32_t n; memcpy(&n, p, 4); return OSSwapLittleToHostInt32(n); }
static uint64_t U64(const void *p) { uint64_t n; memcpy(&n, p, 8); return OSSwapLittleToHostInt64(n); }
static void W32(void *p, uint32_t n) { n = OSSwapHostToLittleInt32(n); memcpy(p, &n, 4); }
static void W64(void *p, uint64_t n) { n = OSSwapHostToLittleInt64(n); memcpy(p, &n, 8); }
static BOOL Range(uint64_t off, uint64_t size, uint64_t end) { return off <= end && size <= end - off; }
static BOOL Arm64(uint32_t cpu, uint32_t sub) {
    return cpu == CPU_TYPE_ARM64 && (sub & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64_ALL;
}
static BOOL FatMagic(uint32_t m) {
    return m == FAT_MAGIC || m == FAT_CIGAM || m == FAT_MAGIC_64 || m == FAT_CIGAM_64;
}
static BOOL Slice(NSData *data, NSRange *slice, NSError **error) {
    const uint8_t *b = data.bytes; NSUInteger len = data.length;
    if (len < 4) return Fail(error, @"Truncated Mach-O magic.");
    uint32_t magic = U32(b);
    if (magic == MH_MAGIC_64) {
        if (len < 32) return Fail(error, @"Truncated Mach-O header.");
        if (!Arm64(U32(b + 4), U32(b + 8))) return Fail(error, @"No plain arm64 slice (arm64e is unsupported).");
        *slice = NSMakeRange(0, len); return YES;
    }
    if (!FatMagic(magic) || len < 8) return Fail(error, @"Not a supported Mach-O binary.");
    BOOL wide = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    BOOL big = magic == FAT_CIGAM || magic == FAT_CIGAM_64;
    uint32_t (^read32)(const void *) = ^uint32_t(const void *p) { uint32_t n = U32(p); return big ? OSSwapInt32(n) : n; };
    uint64_t (^read64)(const void *) = ^uint64_t(const void *p) { uint64_t n = U64(p); return big ? OSSwapInt64(n) : n; };
    uint32_t count = read32(b + 4); uint64_t entrySize = wide ? 32 : 20;
    if (!count || !Range(8, (uint64_t)count * entrySize, len)) return Fail(error, @"Truncated universal architecture table.");
    uint64_t tableEnd = 8 + (uint64_t)count * entrySize;
    BOOL found = NO;
    NSMutableArray<NSValue *> *ranges = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *a = b + 8 + i * entrySize;
        uint64_t off = wide ? read64(a + 8) : read32(a + 8);
        uint64_t size = wide ? read64(a + 16) : read32(a + 12);
        uint32_t align = read32(a + (wide ? 24 : 16));
        if (off < tableEnd || size < 4 || !Range(off, size, len) || align > 63 || (off & ((1ULL << align) - 1)))
            return Fail(error, @"Invalid universal slice bounds/alignment.");
        [ranges addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)off, (NSUInteger)size)]];
        if (!Arm64(read32(a), read32(a + 4))) continue;
        if (found) return Fail(error, @"Ambiguous duplicate arm64 slices.");
        if (size < 32 || U32(b + off) != MH_MAGIC_64 || !Arm64(U32(b + off + 4), U32(b + off + 8)))
            return Fail(error, @"Universal arm64 entry disagrees with its Mach-O header.");
        *slice = NSMakeRange((NSUInteger)off, (NSUInteger)size); found = YES;
    }
    [ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return a.rangeValue.location < b.rangeValue.location ? NSOrderedAscending :
               a.rangeValue.location > b.rangeValue.location ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger previousEnd = 0;
    for (NSValue *value in ranges) {
        NSRange r = value.rangeValue;
        if (r.location < previousEnd) return Fail(error, @"Overlapping universal slices.");
        previousEnd = NSMaxRange(r);
    }
    return found || Fail(error, @"No plain arm64 slice (arm64e is unsupported).");
}
static BOOL DylibLoad(uint32_t cmd) {
    cmd &= ~LC_REQ_DYLD;
    return cmd == LC_LOAD_DYLIB || cmd == (LC_LOAD_WEAK_DYLIB & ~LC_REQ_DYLD) ||
           cmd == (LC_REEXPORT_DYLIB & ~LC_REQ_DYLD) || cmd == LC_LAZY_LOAD_DYLIB ||
           cmd == (LC_LOAD_UPWARD_DYLIB & ~LC_REQ_DYLD);
}
static NSString *CommandString(NSData *command, NSUInteger field, NSUInteger minimum, NSError **error) {
    const uint8_t *b = command.bytes;
    if (command.length < minimum || field + 4 > command.length) { Fail(error, @"Truncated string load command."); return nil; }
    uint32_t start = U32(b + field);
    if (start < minimum || start >= command.length) { Fail(error, @"Invalid load command string offset."); return nil; }
    const uint8_t *end = memchr(b + start, 0, command.length - start);
    if (!end) { Fail(error, @"Unterminated load command string."); return nil; }
    NSString *s = [[NSString alloc] initWithBytes:b + start length:end - (b + start) encoding:NSUTF8StringEncoding];
    if (!s) Fail(error, @"Load command path is not UTF-8.");
    return s;
}
static NSMutableData *NamedCommand(uint32_t cmd, NSData *old, NSString *name, NSUInteger prefix) {
    NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger size = (prefix + utf8.length + 1 + 7) & ~(NSUInteger)7;
    NSMutableData *out = [NSMutableData dataWithLength:size]; uint8_t *b = out.mutableBytes;
    if (old) memcpy(b, old.bytes, MIN(prefix, old.length));
    W32(b, cmd); W32(b + 4, (uint32_t)size); W32(b + 8, (uint32_t)prefix);
    memcpy(b + prefix, utf8.bytes, utf8.length); return out;
}

// Every rewritten command is copied, so no pointer into NSMutableData survives a resize.
// Collect the first occupied byte after the headers; never relocate a code/data payload.
static NSArray<NSMutableData *> *Commands(NSData *data, NSUInteger *firstData, NSError **error) {
    const uint8_t *b = data.bytes; uint64_t len = data.length;
    uint32_t ncmds = U32(b + 16), size = U32(b + 20);
    if (!Range(32, size, len) || ncmds > size / 8) { Fail(error, @"Invalid load command table bounds."); return nil; }
    uint64_t end = 32 + (uint64_t)size, off = 32, first = len;
    NSUInteger segments = 0, ids = 0, mains = 0;
    NSMutableArray *commands = [NSMutableArray arrayWithCapacity:ncmds];
    for (uint32_t i = 0; i < ncmds; i++) {
        if (!Range(off, 8, end)) { Fail(error, @"Truncated load command."); return nil; }
        uint32_t cmd = U32(b + off), cs = U32(b + off + 4);
        if (cs < 8 || (cs & 7) || !Range(off, cs, end)) { Fail(error, @"Invalid load command size/alignment."); return nil; }
        const uint8_t *p = b + off;
        NSMutableData *copy = [[data subdataWithRange:NSMakeRange(off, cs)] mutableCopy];
        if (DylibLoad(cmd) || cmd == LC_ID_DYLIB) {
            if (!CommandString(copy, 8, 24, error)) return nil;
            if (cmd == LC_ID_DYLIB && ++ids > 1) { Fail(error, @"Duplicate dylib identity commands."); return nil; }
        } else if (cmd == LC_RPATH || cmd == LC_LOAD_DYLINKER || cmd == LC_ID_DYLINKER || cmd == LC_DYLD_ENVIRONMENT) {
            if (!CommandString(copy, 8, 12, error)) return nil;
        } else if (cmd == LC_SEGMENT_64) {
            segments++;
            if (cs < 72 || (uint64_t)U32(p + 64) * 80 != cs - 72) { Fail(error, @"Invalid segment/section table."); return nil; }
            uint64_t fileoff = U64(p + 40), filesize = U64(p + 48);
            if (!Range(fileoff, filesize, len)) { Fail(error, @"Segment extends past file."); return nil; }
            if (filesize && fileoff) first = MIN(first, fileoff);
            for (uint32_t s = 0; s < U32(p + 64); s++) {
                const uint8_t *sect = p + 72 + (uint64_t)s * 80;
                uint32_t type = U32(sect + 64) & SECTION_TYPE;
                uint64_t so = U32(sect + 48), sz = U64(sect + 40);
                BOOL zero = type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL;
                if (!zero && sz) {
                    if (so < end || !Range(so, sz, len) || so < fileoff || !Range(so - fileoff, sz, filesize)) {
                        Fail(error, @"Section data overlaps headers or exceeds its segment."); return nil;
                    }
                    first = MIN(first, so);
                }
                uint64_t reloc = U32(sect + 56), nr = U32(sect + 60);
                if (nr && (!Range(reloc, nr * 8, len) || reloc < end)) { Fail(error, @"Invalid section relocations."); return nil; }
                if (nr) first = MIN(first, reloc);
            }
        } else if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            if (cs < (cmd == LC_ENCRYPTION_INFO_64 ? 24 : 20)) { Fail(error, @"Truncated encryption command."); return nil; }
            if (U32(p + 16)) { Fail(error, @"Encrypted Mach-O binaries cannot be prepared."); return nil; }
            if (!Range(U32(p + 8), U32(p + 12), len)) { Fail(error, @"Invalid encryption range."); return nil; }
        } else if (cmd == LC_BUILD_VERSION) {
            if (cs < 24 || !Range(24, (uint64_t)U32(p + 20) * 8, cs)) { Fail(error, @"Truncated build version command."); return nil; }
        } else if (cmd == LC_VERSION_MIN_MACOSX || cmd == LC_VERSION_MIN_IPHONEOS || cmd == LC_VERSION_MIN_TVOS || cmd == LC_VERSION_MIN_WATCHOS) {
            if (cs != 16) { Fail(error, @"Invalid minimum version command."); return nil; }
        } else if (cmd == LC_MAIN) {
            if (cs != 24 || U64(p + 8) >= len || ++mains > 1) { Fail(error, @"Invalid main entry point."); return nil; }
        } else if (cmd == LC_SYMTAB) {
            if (cs != 24 || !Range(U32(p + 8), (uint64_t)U32(p + 12) * 16, len) || !Range(U32(p + 16), U32(p + 20), len)) {
                Fail(error, @"Invalid symbol table."); return nil;
            }
            if (U32(p + 12)) first = MIN(first, U32(p + 8));
            if (U32(p + 20)) first = MIN(first, U32(p + 16));
        } else if (cmd == LC_DYSYMTAB) {
            if (cs != 80) { Fail(error, @"Invalid dynamic symbol table command."); return nil; }
            const uint32_t widths[] = {8, 56, 4, 4, 8, 8};
            for (int f = 32; f < 80; f += 8) {
                uint32_t o = U32(p + f), n = U32(p + f + 4);
                if (!Range(o, (uint64_t)n * widths[(f - 32) / 8], len)) { Fail(error, @"Invalid dynamic symbol table data range."); return nil; }
                if (n) first = MIN(first, o);
            }
        } else if (cmd == LC_UUID) {
            if (cs != 24) { Fail(error, @"Invalid UUID command."); return nil; }
        } else if (cmd == LC_DYLD_INFO || cmd == LC_DYLD_INFO_ONLY) {
            if (cs != 48) { Fail(error, @"Invalid dyld info command."); return nil; }
            for (int f = 8; f < 48; f += 8) {
                uint32_t o = U32(p + f), n = U32(p + f + 4);
                if (!Range(o, n, len)) { Fail(error, @"Invalid dyld info data range."); return nil; }
                if (n) first = MIN(first, o);
            }
        } else if (cmd == LC_CODE_SIGNATURE || cmd == LC_SEGMENT_SPLIT_INFO || cmd == LC_FUNCTION_STARTS ||
                   cmd == LC_DATA_IN_CODE || cmd == LC_DYLIB_CODE_SIGN_DRS || cmd == LC_LINKER_OPTIMIZATION_HINT ||
                   cmd == LC_DYLD_EXPORTS_TRIE || cmd == LC_DYLD_CHAINED_FIXUPS) {
            if (cs != 16 || !Range(U32(p + 8), U32(p + 12), len)) { Fail(error, @"Invalid linkedit data range."); return nil; }
            if (U32(p + 12)) first = MIN(first, U32(p + 8));
        }
        [commands addObject:copy]; off += cs;
    }
    if (!segments || off != end || first < end) { Fail(error, @"Load commands overlap file data or disagree with header size."); return nil; }
    if (U32(b + 12) == MH_DYLIB && ids != 1) { Fail(error, @"Dylib has no identity command."); return nil; }
    if (U32(b + 12) == MH_EXECUTE && ids) { Fail(error, @"Executable already contains a dylib identity command."); return nil; }
    *firstData = (NSUInteger)first; return commands;
}

static NSDictionary<NSString *, NSString *> *LinkMap(void) {
    return @{@"AppKit": @"AppKit", @"Cocoa": @"AppKit", @"Foundation": @"AppKit", @"Carbon": @"Carbon",
             @"CoreServices": @"Carbon", @"CoreGraphics": @"CG", @"CoreVideo": @"CV", @"IOKit": @"IOKit",
             @"CoreAudio": @"CoreAudio", @"AudioToolbox": @"AudioToolbox", @"AudioUnit": @"AudioToolbox",
             @"OpenGL": @"OpenGL", @"AGL": @"OpenGL", @"GLUT": @"OpenGL", @"Security": @"Security", @"AVFoundation": @"AVFoundation",
             @"libSystem": @"System", @"SwiftUI": @"SwiftUI", @"ForceFeedback": @"IOKit", @"Quartz": @"AppKit", @"QuartzCore": @"AppKit",
             @"SecurityFoundation": @"Security", @"ApplicationServices": @"CG", @"Metal": @"CV",
             @"OpenCL": @"System", @"LDAP": @"System", @"CFNetwork": @"System", @"libswiftCore": @"System", @"libcurl": @"System"};   // see LINK_MAP in prep/shackprep.py
}
static NSString *FrameworkName(NSString *path) {
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSString *p in parts) if ([p hasSuffix:@".framework"]) return [p stringByDeletingPathExtension];
    NSString *swift = @"/usr/lib/swift/";   // the OS Swift runtime, as framework_name in prep/shackprep.py
    if ([path hasPrefix:swift] && [path hasSuffix:@".dylib"] && parts.count == 5 && [parts[4] hasPrefix:@"lib"])
        return [parts[4] stringByDeletingPathExtension];
    if ([path isEqualToString:@"/usr/lib/libcurl.4.dylib"]) return @"libcurl";
    return [path isEqualToString:@"/usr/lib/libSystem.B.dylib"] ? @"libSystem" : nil;
}
static NSString *StripFrameworkVersions(NSString *path) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\.framework/Versions/[A-Z]/" options:0 error:nil];
    return [re stringByReplacingMatchesInString:path options:0 range:NSMakeRange(0, path.length) withTemplate:@".framework/"];
}
static NSString *LoaderPath(NSString *path, NSString *exeDir, NSString *input) {
    NSArray *from = [[input.stringByDeletingLastPathComponent stringByStandardizingPath] pathComponents];
    NSArray *to = [[exeDir stringByStandardizingPath] pathComponents];
    NSUInteger common = 0;
    while (common < from.count && common < to.count && [from[common] isEqual:to[common]]) common++;
    NSMutableArray *relative = [NSMutableArray array];
    for (NSUInteger i = common; i < from.count; i++) [relative addObject:@".."];
    for (NSUInteger i = common; i < to.count; i++) [relative addObject:to[i]];
    NSString *suffix = [path substringFromIndex:@"@executable_path".length];
    for (NSString *part in [suffix componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."] && relative.count && ![relative.lastObject isEqualToString:@".."]) [relative removeLastObject];
        else [relative addObject:part];
    }
    return [@"@loader_path/" stringByAppendingString:relative.count ? [relative componentsJoinedByString:@"/"] : @"."];
}

@implementation ShackPrep
+ (NSString *)hostLibraryForInstallName:(NSString *)installName {
    NSString *fw = FrameworkName(installName), *shim = fw ? LinkMap()[fw] : nil;
    if (shim) return [NSString stringWithFormat:@"@rpath/libShack%@.dylib", shim];
    return fw ? StripFrameworkVersions(installName) : nil;
}

+ (BOOL)isMachOAtPath:(NSString *)path {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return NO;
    NSData *head = [file readDataUpToLength:4 error:nil]; [file closeFile];
    if (head.length != 4) return NO;
    uint32_t m = U32(head.bytes); return m == MH_MAGIC_64 || m == MH_CIGAM_64 || m == MH_MAGIC || m == MH_CIGAM || FatMagic(m);
}
+ (BOOL)hasArm64AtPath:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (!data) return NO;
    NSRange range; return Slice(data, &range, error);
}
+ (NSString *)monoRevisionAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    const uint8_t *b = data.bytes; const char prefix[] = "explicit/";
    for (NSUInteger i = 0; i + sizeof(prefix) < data.length; i++) {
        if (memcmp(b + i, prefix, sizeof(prefix) - 1)) continue;
        NSUInteger start = i + sizeof(prefix) - 1, end = start;
        while (end < data.length && end - start < 40 && ((b[end] >= '0' && b[end] <= '9') || (b[end] >= 'a' && b[end] <= 'f'))) end++;
        if (end - start >= 7) return [[NSString alloc] initWithBytes:b + start length:end - start encoding:NSASCIIStringEncoding];
    }
    return nil;
}
+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory mainExecutable:(BOOL)mainExecutable error:(NSError **)error {
    return [self prepareBinaryAtPath:inputPath outputPath:outputPath executableDirectory:executableDirectory
                      mainExecutable:mainExecutable loaderPathShift:nil error:error];
}
static NSString *ShiftedLoaderPath(NSString *path, NSString *shift) {
    if (!shift.length) return path;
    if ([path isEqualToString:@"@loader_path"]) return [@"@loader_path/" stringByAppendingString:shift];
    if (![path hasPrefix:@"@loader_path/"]) return path;
    return [@"@loader_path/" stringByAppendingPathComponent:[shift stringByAppendingPathComponent:[path substringFromIndex:@"@loader_path/".length]]];
}
+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory mainExecutable:(BOOL)mainExecutable
           loaderPathShift:(NSString *)loaderPathShift error:(NSError **)error {
    return [self prepareBinaryAtPath:inputPath outputPath:outputPath executableDirectory:executableDirectory
                      mainExecutable:mainExecutable loaderPathShift:loaderPathShift linkMap:nil error:error];
}
// Cyberpunk 2077 (REDengine): at start its memory pools reserve ~139 GB of address space with mmap (16 + 64 + 32 GB, six
// of 4 GB, ...), whatever the RAM. An iOS app has ~55 GB of address space: the 64 GB mmap fails, that pool never
// registers, and a static initializer reads its name from NULL + 0x28 (2026-10-07). Each pool fills its range from the
// bottom (Mac, title screen: 600 of 16384 MB, 703 of 65536, <20 MB of each 4 GB), so a quarter of every reservation of
// 4 GB or more (~37 GB in all) fails only a pool that really outgrows it. Every reservation goes through two helpers
// returning {base, base + size}, size = roundup(request, align): H1 (align in w2) and H2 (the same after checking
// w4 == w2). Found by their code, not their address, so other store builds of the same engine match too. H2 becomes
// "check, then tail-call H1"; its freed body holds the clamp, which H1 jumps to in place of `and x19, x9, x8`.
// Returns the reservations patched (0: not this engine, or already patched).
static uint32_t Branch(NSUInteger from, NSUInteger to) { return 0x14000000 | (((uint32_t)((int64_t)(to - from) >> 2)) & 0x3FFFFFF); }
static NSUInteger PatchREDPoolReservations(NSMutableData *data) {
    static const uint32_t body[] = {0x8B080029, 0xD1000529, 0xCB0803E8, 0x8A080133,   // add x9, x1, x8 ... and x19, x9, x8
                                    0xD2800000, 0xAA1303E1, 0x52800062, 0x52820043, 0x12800004, 0xD2800005};   // mmap(0, x19, RW, ANON|PRIVATE, -1, 0)
    static const uint32_t prologue[] = {0xA9BE4FF4, 0xA9017BFD, 0x910043FD};   // stp x20, x19, [sp, #-0x20]!; stp x29, x30, ...; add x29, sp, #0x10
    uint32_t h1[14], h2[14];
    memcpy(h1, prologue, 12); h1[3] = 0x2A0203E8; memcpy(h1 + 4, body, 40);   // mov w8, w2
    memcpy(h2, prologue, 12); h2[3] = 0x2A0403E8; memcpy(h2 + 4, body, 40);   // mov w8, w4
    uint8_t *b = data.mutableBytes; NSUInteger n = data.length;
    NSUInteger at[2]; const uint32_t *find[2] = {h1, h2};
    for (int k = 0; k < 2; k++) {
        NSRange r = [data rangeOfData:[NSData dataWithBytesNoCopy:(void *)find[k] length:56 freeWhenDone:NO] options:0 range:NSMakeRange(0, n)];
        if (r.location == NSNotFound || r.location & 3) return 0;
        NSUInteger next = r.location + 4;
        if ([data rangeOfData:[NSData dataWithBytesNoCopy:(void *)find[k] length:56 freeWhenDone:NO] options:0 range:NSMakeRange(next, n - next)].location != NSNotFound) return 0;
        at[k] = r.location;
    }
    if (at[1] < 8 || U32(b + at[1] - 8) != 0x6B02009F || (U32(b + at[1] - 4) & 0xFF00001F) != 0x54000001) return 0;   // cmp w4, w2; b.ne
    NSUInteger h1And = at[0] + 28, resume = at[0] + 32, cave = at[1] + 4;
    W32(b + at[1], Branch(at[1], at[0]));   // H2: b H1
    W32(b + h1And, Branch(h1And, cave));   // H1: b clamp
    uint32_t clamp[] = {0x8A080133,   // and x19, x9, x8    (size rounded up to the alignment)
                        0xD360FE69,   // lsr x9, x19, #32
                        0xB4000009 | ((((uint32_t)((int64_t)(resume - (cave + 8)) >> 2)) & 0x7FFFF) << 5),   // cbz x9, resume (under 4 GB)
                        0xD342FE73,   // lsr x19, x19, #2
                        0x8A080273,   // and x19, x19, x8   (x8 = -align)
                        Branch(cave + 20, resume)};
    for (int i = 0; i < 6; i++) W32(b + cave + 4 * i, clamp[i]);
    return 2;
}

+ (BOOL)prepareBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath
       executableDirectory:(NSString *)executableDirectory mainExecutable:(BOOL)mainExecutable
           loaderPathShift:(NSString *)loaderPathShift linkMap:(NSDictionary<NSString *, NSString *> *)linkMap
                     error:(NSError **)error {
    if (error) *error = nil;
    NSData *source = [NSData dataWithContentsOfFile:inputPath options:NSDataReadingMappedIfSafe error:error];
    if (!source) return NO;
    NSRange slice; if (!Slice(source, &slice, error)) return NO;
    NSMutableData *data = [[source subdataWithRange:slice] mutableCopy];
    if (mainExecutable && PatchREDPoolReservations(data)) NSLog(@"[ShackPrep] %@: REDengine pools reserve a quarter of 4 GB+", inputPath.lastPathComponent);
    uint8_t *b = data.mutableBytes; uint32_t type = U32(b + 12), oldSize = U32(b + 20);
    if (type != MH_EXECUTE && type != MH_DYLIB && type != MH_BUNDLE) return Fail(error, @"Unsupported Mach-O file type.");
    NSUInteger firstData;
    NSArray<NSMutableData *> *original = Commands(data, &firstData, error); if (!original) return NO;
    if (mainExecutable) {
        BOOL hasEntry = NO;
        for (NSData *c in original) if (U32(c.bytes) == LC_MAIN) hasEntry = YES;
        if (type == MH_BUNDLE || !hasEntry) return Fail(error, @"Main executable needs an LC_MAIN entry point.");
    }
    NSMutableArray<NSMutableData *> *commands = [NSMutableArray array];
    BOOL convert = mainExecutable && type == MH_EXECUTE, seenID = NO, hasLoad = NO;
    NSMutableSet *used = [NSMutableSet set];
    for (NSData *c in original) {
        uint32_t cmd = U32(c.bytes);
        if (DylibLoad(cmd) || cmd == LC_ID_DYLIB) [used addObject:CommandString(c, 8, 24, nil)];
        if (DylibLoad(cmd)) hasLoad = YES;
    }
    for (NSMutableData * __strong c in original) {
        uint8_t *p = c.mutableBytes; uint32_t cmd = U32(p);
        if (cmd == LC_BUILD_VERSION || cmd == LC_VERSION_MIN_MACOSX || cmd == LC_VERSION_MIN_IPHONEOS ||
            cmd == LC_VERSION_MIN_TVOS || cmd == LC_VERSION_MIN_WATCHOS) continue;
        if (convert && cmd == LC_SEGMENT_64 && !memcmp(p + 8, "__PAGEZERO\0", 11)) {
            W64(p + 24, 0x100000000ULL - 0x4000); W64(p + 32, 0x4000);
        }
        if (convert && cmd == LC_LOAD_DYLINKER && !seenID) {
            c = NamedCommand(LC_ID_DYLIB, nil, @"guest", 24); p = c.mutableBytes;
            W32(p + 16, 0x10000); W32(p + 20, 0x10000); seenID = YES;
        }
        [commands addObject:c];
    }
    if (convert && !seenID) return Fail(error, @"Main executable has no LC_LOAD_DYLINKER to convert.");
    // Match vtool -set-build-version ios 16.0 26.4 -replace; old tool version records are discarded.
    NSMutableData *version = [NSMutableData dataWithLength:24]; uint8_t *v = version.mutableBytes;
    W32(v, LC_BUILD_VERSION); W32(v + 4, 24); W32(v + 8, PLATFORM_IOS); W32(v + 12, 16 << 16); W32(v + 16, (26 << 16) | (4 << 8));
    [commands addObject:version];
    if ((convert || type == MH_DYLIB) && !hasLoad) {
        for (NSUInteger i = 0; i < commands.count; i++) {
            if (U32(commands[i].bytes) == LC_ID_DYLIB) commands[i] = NamedCommand(LC_ID_DYLIB, commands[i], @"burst", 24);
        }
        NSMutableData *lib = NamedCommand(LC_LOAD_DYLIB, nil, @"/usr/lib/libSystem.B.dylib", 24); uint8_t *p = lib.mutableBytes;
        W32(p + 12, 2); W32(p + 16, 0x10000); W32(p + 20, 0x10000); [commands addObject:lib];
        [used addObject:@"/usr/lib/libSystem.B.dylib"];
    }
    NSSet *unsupported = [NSSet setWithArray:@[@"CoreWLAN", @"DiscRecording", @"InstallerPlugins", @"ScreenSaver", @"SecurityInterface"]];
    NSDictionary *map = LinkMap();
    for (NSUInteger i = 0; i < commands.count; i++) {
        NSData *c = commands[i]; uint32_t cmd = U32(c.bytes);
        if (cmd == LC_RPATH) {
            NSString *old = CommandString(c, 8, 12, error);
            if ([old isEqualToString:@"@executable_path"] || [old hasPrefix:@"@executable_path/"])
                commands[i] = NamedCommand(cmd, c, LoaderPath(old, executableDirectory, inputPath), 12);
            else if (ShiftedLoaderPath(old, loaderPathShift) != old)
                commands[i] = NamedCommand(cmd, c, ShiftedLoaderPath(old, loaderPathShift), 12);
        } else if (DylibLoad(cmd)) {
            NSString *old = CommandString(c, 8, 24, error), *new = old;
            if ([old hasPrefix:@"@executable_path/"]) new = LoaderPath(old, executableDirectory, inputPath);
            else if (ShiftedLoaderPath(old, loaderPathShift) != old) new = ShiftedLoaderPath(old, loaderPathShift);
            else {
                NSString *fw = FrameworkName(old), *shim = linkMap[old] ?: (fw ? linkMap[fw] ?: map[fw] : nil);
                if (shim) new = [shim hasPrefix:@"@"] ? shim : [NSString stringWithFormat:@"@rpath/libShack%@.dylib", shim];
                else if (fw && [unsupported containsObject:fw]) return Fail(error, [NSString stringWithFormat:@"macOS-only framework has no shim mapping: %@", fw]);
                else if (fw) new = StripFrameworkVersions(old);
                while (![new isEqualToString:old] && [used containsObject:new]) {
                    if (![new hasPrefix:@"@rpath/"]) return Fail(error, @"Rewriting would duplicate a linked dylib.");
                    new = [@"@rpath/./" stringByAppendingString:[new substringFromIndex:7]];
                }
            }
            [used addObject:new];
            if (![new isEqualToString:old]) commands[i] = NamedCommand(cmd, c, new, 24);
        } else if (cmd == LC_ID_DYLIB && [linkMap[CommandString(c, 8, 24, nil)] hasPrefix:@"@"]) {
            commands[i] = NamedCommand(cmd, c, linkMap[CommandString(c, 8, 24, nil)], 24);   // a private copy's own name
        }
    }
    NSMutableData *blob = [NSMutableData data]; for (NSData *c in commands) [blob appendData:c];
    if (blob.length > UINT32_MAX || blob.length + 32 > firstData) return Fail(error, @"Insufficient Mach-O header padding for rewritten load commands.");
    // Do not assume unsectioned bytes between the command table and first section are free.
    for (NSUInteger off = 32 + oldSize; off < 32 + blob.length; off++)
        if (b[off]) return Fail(error, @"Mach-O header growth would overwrite nonzero data.");
    memset(b + 32, 0, MAX(oldSize, blob.length)); memcpy(b + 32, blob.bytes, blob.length);
    W32(b + 16, (uint32_t)commands.count); W32(b + 20, (uint32_t)blob.length);
    if (convert) { W32(b + 12, MH_DYLIB); W32(b + 24, (U32(b + 24) | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE); W32(b + 28, 0); }
    return [data writeToFile:outputPath options:NSDataWritingAtomic error:error];
}
@end
