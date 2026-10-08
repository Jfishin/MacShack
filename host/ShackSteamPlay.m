#import "ShackSteamPlay.h"
#import <mach-o/fat.h>
#import <mach-o/loader.h>

// macOS Steam ships Steam Play switched off (CCompatManager enables it only on Linux). NotProton, the Mac add-on that
// turns it on, does it with inline hooks; iOS code cannot be patched while it runs, but MacShack signs Steam's code
// itself, so the same switches become instruction changes in the prepared copy. Facts about Valve's client, found by
// prep/steam-onehost/steamplay_sites.py in client 1788652215 (the build MacShack pins).
typedef struct { uint64_t address; uint32_t original, patched; } SteamPlaySite;
static const SteamPlaySite kSites[] = {
    {0x6913bc, 0x1a9f17e8, 0x52800028},   // CCompatManager::Init: enabled = (platform == "linux") -> enabled = 1
    {0x69382c, 0x391ec27f, 0xd503201f},   // "Disabling compatibility layer." no longer clears it
    {0x695ed0, 0xb4fffcc0, 0xd503201f},   // GetOSListOverrideForApp: the tool's from_oslist overrides (Windows depots)
};
enum { kSiteCount = sizeof kSites / sizeof *kSites };

// The arm64 slice of a universal or thin Mach-O: its offset and size in the file.
static BOOL arm64Slice(NSData *file, uint64_t *offset, uint64_t *size) {
    const uint8_t *b = file.bytes;
    if (file.length < sizeof(struct mach_header_64)) return NO;
    uint32_t magic = *(const uint32_t *)b;
    if (magic == MH_MAGIC_64) {
        if (((const struct mach_header_64 *)b)->cputype != CPU_TYPE_ARM64) return NO;
        *offset = 0; *size = file.length;
        return YES;
    }
    if (magic != FAT_CIGAM) return NO;   // the universal header is big-endian
    uint32_t n = OSSwapBigToHostInt32(((const struct fat_header *)b)->nfat_arch);
    for (uint32_t i = 0; i < n && sizeof(struct fat_header) + (i + 1) * sizeof(struct fat_arch) <= file.length; i++) {
        const struct fat_arch *a = (const void *)(b + sizeof(struct fat_header) + i * sizeof(struct fat_arch));
        if ((cpu_type_t)OSSwapBigToHostInt32(a->cputype) != CPU_TYPE_ARM64) continue;
        *offset = OSSwapBigToHostInt32(a->offset); *size = OSSwapBigToHostInt32(a->size);
        return *offset + *size <= file.length;
    }
    return NO;
}

// __TEXT's address and file offset within the slice (instruction addresses map to the file through it).
static BOOL textSegment(const uint8_t *macho, uint64_t size, uint64_t *vmaddr, uint64_t *fileoff) {
    const struct mach_header_64 *h = (const void *)macho;
    const uint8_t *lc = macho + sizeof *h, *end = lc + h->sizeofcmds;
    if (end > macho + size) return NO;
    for (uint32_t i = 0; i < h->ncmds && lc + sizeof(struct load_command) <= end; i++) {
        const struct segment_command_64 *seg = (const void *)lc;
        if (seg->cmd == LC_SEGMENT_64 && !strncmp(seg->segname, SEG_TEXT, sizeof seg->segname)) {
            *vmaddr = seg->vmaddr; *fileoff = seg->fileoff;
            return YES;
        }
        lc += ((const struct load_command *)lc)->cmdsize;
    }
    return NO;
}

static NSString *patchFile(NSString *path, BOOL write) {
    NSMutableData *file = [NSMutableData dataWithContentsOfFile:path];
    uint64_t slice = 0, sliceSize = 0, vmaddr = 0, fileoff = 0;
    if (!file) return @"not patched: unreadable";
    if (!arm64Slice(file, &slice, &sliceSize) || !textSegment((const uint8_t *)file.bytes + slice, sliceSize, &vmaddr, &fileoff))
        return @"not patched: no arm64 Mach-O";
    uint8_t *bytes = file.mutableBytes;
    uint64_t at[kSiteCount];
    size_t todo = 0;
    for (size_t i = 0; i < kSiteCount; i++) {   // every site checked before anything is written
        at[i] = slice + fileoff + kSites[i].address - vmaddr;
        if (kSites[i].address < vmaddr || at[i] + 4 > slice + sliceSize) return @"not patched: a site lies outside the code";
        uint32_t word;
        memcpy(&word, bytes + at[i], 4);
        if (word == kSites[i].original) todo++;
        else if (word != kSites[i].patched)
            return [NSString stringWithFormat:@"not patched: 0x%llx holds 0x%08x, not 0x%08x (another Steam build)",
                    kSites[i].address, word, kSites[i].original];
    }
    if (!todo) return @"already patched";
    if (!write) return [NSString stringWithFormat:@"would patch %zu site(s)", todo];
    for (size_t i = 0; i < kSiteCount; i++) memcpy(bytes + at[i], &kSites[i].patched, 4);
    if (![file writeToFile:path atomically:YES]) return @"not patched: write failed";
    return [NSString stringWithFormat:@"patched %zu site(s)", todo];
}

NSString *ShackSteamPlayPatch(NSString *path) { return patchFile(path, YES); }
NSString *ShackSteamPlayCheck(NSString *path) { return patchFile(path, NO); }

// --- Before Steam starts ---

NSString *const ShackSteamPlayTool = @"macshack_proton";

BOOL ShackSteamPlayIsTool(const char *path) {
    return path && strstr(path, "/compatibilitytools.d/macshack_proton/") != NULL;
}

NSString *ShackVDFAddCompatMapping(NSString *config, NSString *tool) {
    if ([config containsString:@"\"CompatToolMapping\""]) return nil;
    static NSString *const steam = @"\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n";
    NSRange at = [config rangeOfString:steam];
    if (at.location == NSNotFound) return nil;
    NSString *mapping = [NSString stringWithFormat:@"\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t\t\"0\"\n\t\t\t\t\t{\n"
                         "\t\t\t\t\t\t\"name\"\t\t\"%@\"\n\t\t\t\t\t\t\"config\"\t\t\"\"\n\t\t\t\t\t\t\"priority\"\t\t\"75\"\n"
                         "\t\t\t\t\t}\n\t\t\t\t}\n", tool];
    NSMutableString *out = [config mutableCopy];
    [out insertString:mapping atIndex:NSMaxRange(at)];
    return out;
}

NSString *ShackVDFAddLibrary(NSString *folders, NSString *path, NSString *label, NSString *contentID) {
    if ([folders containsString:[NSString stringWithFormat:@"\"%@\"", path]]) return nil;
    NSRange close = [folders rangeOfString:@"}" options:NSBackwardsSearch];
    if (close.location == NSNotFound) return nil;
    NSInteger next = 0;   // the entries are "0", "1", ... at the top level
    NSRegularExpression *index = [NSRegularExpression regularExpressionWithPattern:@"\n\t\"(\\d+)\"\n\t\\{" options:0 error:nil];
    for (NSTextCheckingResult *r in [index matchesInString:folders options:0 range:NSMakeRange(0, folders.length)])
        next = MAX(next, [folders substringWithRange:[r rangeAtIndex:1]].integerValue + 1);
    NSString *entry = [NSString stringWithFormat:@"\t\"%ld\"\n\t{\n\t\t\"path\"\t\t\"%@\"\n\t\t\"label\"\t\t\"%@\"\n\t\t\"contentid\"\t\t\"%@\"\n"
                       "\t\t\"totalsize\"\t\t\"0\"\n\t\t\"update_clean_bytes_tally\"\t\t\"0\"\n\t\t\"time_last_update_verified\"\t\t\"0\"\n"
                       "\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n", (long)next, path, label, contentID];
    NSMutableString *out = [folders mutableCopy];
    [out insertString:entry atIndex:close.location];
    return out;
}

// A Steam that never ran has no such file yet (a new user's first Big Picture): `empty` stands in for it, so the
// change is there before Steam first reads the file. Removal passes `empty` nil: no file, nothing to undo.
static void edit(NSString *path, NSString *empty, NSString *_Nullable (^change)(NSString *text)) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) {   // only a missing file may use `empty`; one that exists but is not readable UTF-8 is Steam's: not ours to overwrite
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return NSLog(@"[MacShack] Steam Play: %@ is not readable UTF-8 text, left alone", path.lastPathComponent);
        text = empty;
    }
    if (!text) return;   // nothing to undo in a file Steam never wrote
    NSString *changed = change(text);
    if (!changed) return;
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [changed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[MacShack] Steam Play: %@ %@", ok ? @"updated" : @"COULD NOT UPDATE", path.lastPathComponent);
}

void ShackSteamPlaySetup(NSString *steam, NSURL *group) {
    NSFileManager *fm = NSFileManager.defaultManager;
    // The tool, laid out as compatibilitytools.d tools are (Proton-GE, NotProton). macOS Steam scans the folder only
    // when STEAM_EXTRA_COMPAT_TOOLS_PATHS names it. `run` is never executed: Steam's spawn of it is a Windows program
    // for MacShack Play (ShackSteamClient.m).
    NSString *tools = [steam stringByAppendingPathComponent:@"compatibilitytools.d"];
    NSString *dir = [tools stringByAppendingPathComponent:ShackSteamPlayTool];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary<NSString *, NSString *> *files = @{
        @"compatibilitytool.vdf": [NSString stringWithFormat:@"\"compatibilitytools\"\n{\n\t\"compat_tools\"\n\t{\n\t\t\"%@\"\n\t\t{\n"
                                   "\t\t\t\"install_path\"\t\t\".\"\n\t\t\t\"display_name\"\t\t\"MacShack Play\"\n"
                                   "\t\t\t\"from_oslist\"\t\t\"windows\"\n\t\t\t\"to_oslist\"\t\t\"macos\"\n\t\t}\n\t}\n}\n", ShackSteamPlayTool],
        @"toolmanifest.vdf": @"\"manifest\"\n{\n\t\"version\"\t\t\"2\"\n\t\"commandline\"\t\t\"/run %verb%\"\n}\n",
        @"run": @"#!/bin/sh\n# MacShack: Steam starts this for a Windows game; MacShack runs the game in MacShack Play instead.\nexit 1\n",
    };
    for (NSString *name in files) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqualToString:files[name]]) continue;
        [files[name] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:path error:nil];
    }
    setenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS", tools.fileSystemRepresentation, 1);
    // Windows-only games use the tool: Steam's own global mapping, as "Enable Steam Play for all other titles" sets it.
    edit([steam stringByAppendingPathComponent:@"config/config.vdf"],
         @"\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t}\n\t\t}\n\t}\n}\n",
         ^NSString *(NSString *t) { return ShackVDFAddCompatMapping(t, ShackSteamPlayTool); });
    // The App Group's SteamLibrary: Windows games and their compatdata (prefixes) live where MacShack Play reads them.
    if (!group) return NSLog(@"[MacShack] Steam Play: no App Group container, no MacShack Play library");
    NSString *library = [group.path stringByAppendingPathComponent:@"SteamLibrary"];
    [fm createDirectoryAtPath:[library stringByAppendingPathComponent:@"steamapps"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *marker = [library stringByAppendingPathComponent:@"libraryfolder.vdf"];
    NSString *existing = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
    NSRegularExpression *cid = [NSRegularExpression regularExpressionWithPattern:@"\"contentid\"\\s+\"(\\d+)\"" options:0 error:nil];
    NSTextCheckingResult *found = existing ? [cid firstMatchInString:existing options:0 range:NSMakeRange(0, existing.length)] : nil;
    NSString *contentID = found ? [existing substringWithRange:[found rangeAtIndex:1]]
                                : [NSString stringWithFormat:@"%llu", ((unsigned long long)arc4random() << 31) ^ arc4random()];
    if (!found)
        [[NSString stringWithFormat:@"\"libraryfolder\"\n{\n\t\"contentid\"\t\t\"%@\"\n\t\"label\"\t\t\"MacShack Play\"\n}\n", contentID]
            writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // A fresh Steam's list: its own folder as library 0, as Steam writes it on its first run.
    NSString *steamLibrary = ShackVDFAddLibrary(@"\"libraryfolders\"\n{\n}\n", steam, @"",
                                                [NSString stringWithFormat:@"%llu", ((unsigned long long)arc4random() << 31) ^ arc4random()]);
    for (NSString *folders in @[@"steamapps/libraryfolders.vdf", @"config/libraryfolders.vdf"])
        edit([steam stringByAppendingPathComponent:folders], steamLibrary,
             ^NSString *(NSString *t) { return ShackVDFAddLibrary(t, library, @"MacShack Play", contentID); });
}

// --- After Windows games are removed ---

// The block `"key"` <whitespace> `{ ... }` found first in `range` of `text`, as whole lines (from the key's line to its
// closing brace's line). Quote-aware: VDF values are quoted and may hold braces. Location NSNotFound: none.
static NSRange vdfBlock(NSString *text, NSString *key, NSRange range) {
    NSString *quoted = [NSString stringWithFormat:@"\"%@\"", key];
    NSUInteger end = NSMaxRange(range);
    NSRange name = [text rangeOfString:quoted options:0 range:range];
    while (name.location != NSNotFound) {
        NSUInteger i = NSMaxRange(name);
        while (i < end && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[text characterAtIndex:i]]) i++;
        if (i < end && [text characterAtIndex:i] == '{') {
            NSInteger depth = 0;
            BOOL inQuotes = NO;
            for (NSUInteger j = i; j < end; j++) {
                unichar c = [text characterAtIndex:j];
                if (inQuotes && c == '\\') { j++; continue; }
                if (c == '"') inQuotes = !inQuotes;
                else if (!inQuotes && c == '{') depth++;
                else if (!inQuotes && c == '}' && --depth == 0) {
                    NSUInteger start = [text lineRangeForRange:NSMakeRange(name.location, 0)].location;
                    return NSMakeRange(start, NSMaxRange([text lineRangeForRange:NSMakeRange(j, 0)]) - start);
                }
            }
            return NSMakeRange(NSNotFound, 0);   // unbalanced: not a shape we edit
        }
        name = [text rangeOfString:quoted options:0 range:NSMakeRange(NSMaxRange(name), end - NSMaxRange(name))];
    }
    return NSMakeRange(NSNotFound, 0);
}

NSString *ShackVDFRemoveCompatMapping(NSString *config, NSString *tool) {
    NSRange mapping = vdfBlock(config, @"CompatToolMapping", NSMakeRange(0, config.length));
    if (mapping.location == NSNotFound) return nil;
    NSUInteger innerStart = NSMaxRange([config lineRangeForRange:NSMakeRange(mapping.location, 0)]);
    NSRange inner = NSMakeRange(innerStart, NSMaxRange(mapping) - innerStart);
    NSString *names = [NSString stringWithFormat:@"\"name\"\t\t\"%@\"", tool];
    NSRegularExpression *entryKey = [NSRegularExpression regularExpressionWithPattern:@"^\\t*\"([^\"]+)\"\\n\\t*\\{"
                                                                              options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSMutableArray<NSValue *> *ours = [NSMutableArray array];   // entries ("0" global, an app id per game) naming the tool
    for (NSTextCheckingResult *k in [entryKey matchesInString:config options:0 range:inner]) {
        NSRange entry = vdfBlock(config, [config substringWithRange:[k rangeAtIndex:1]], NSMakeRange(k.range.location, NSMaxRange(inner) - k.range.location));
        if (entry.location != NSNotFound && [[config substringWithRange:entry] containsString:names]) [ours addObject:[NSValue valueWithRange:entry]];
    }
    if (!ours.count) return nil;
    NSMutableString *out = [config mutableCopy];
    for (NSValue *entry in ours.reverseObjectEnumerator) [out deleteCharactersInRange:entry.rangeValue];
    // A mapping left empty goes too: Steam's file as it was before ShackVDFAddCompatMapping.
    NSRange left = vdfBlock(out, @"CompatToolMapping", NSMakeRange(0, out.length));
    if (left.location != NSNotFound && [[out substringWithRange:left] componentsSeparatedByString:@"{"].count == 2) [out deleteCharactersInRange:left];
    return out;
}

// ponytail: the later entries keep their numbers (a gap where ours was); Steam renumbers when it next writes the file.
NSString *ShackVDFRemoveLibrary(NSString *folders, NSString *path) {
    NSString *ours = [NSString stringWithFormat:@"\"path\"\t\t\"%@\"", path];
    NSRegularExpression *entryKey = [NSRegularExpression regularExpressionWithPattern:@"^\\t\"(\\d+)\"\\n\\t\\{"
                                                                              options:NSRegularExpressionAnchorsMatchLines error:nil];
    for (NSTextCheckingResult *k in [entryKey matchesInString:folders options:0 range:NSMakeRange(0, folders.length)]) {
        NSRange entry = vdfBlock(folders, [folders substringWithRange:[k rangeAtIndex:1]], NSMakeRange(k.range.location, folders.length - k.range.location));
        if (entry.location == NSNotFound || ![[folders substringWithRange:entry] containsString:ours]) continue;
        NSMutableString *out = [folders mutableCopy];
        [out deleteCharactersInRange:entry];
        return out;
    }
    return nil;
}

void ShackSteamPlayRemove(NSString *steam, NSURL *group) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [[steam stringByAppendingPathComponent:@"compatibilitytools.d"] stringByAppendingPathComponent:ShackSteamPlayTool];
    if ([fm fileExistsAtPath:dir] && [fm removeItemAtPath:dir error:nil]) NSLog(@"[MacShack] Steam Play off: removed the %@ tool", ShackSteamPlayTool);
    unsetenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS");
    edit([steam stringByAppendingPathComponent:@"config/config.vdf"], nil,
         ^NSString *(NSString *t) { return ShackVDFRemoveCompatMapping(t, ShackSteamPlayTool); });
    if (!group) return;
    NSString *library = [group.path stringByAppendingPathComponent:@"SteamLibrary"];
    for (NSString *folders in @[@"steamapps/libraryfolders.vdf", @"config/libraryfolders.vdf"])
        edit([steam stringByAppendingPathComponent:folders], nil, ^NSString *(NSString *t) { return ShackVDFRemoveLibrary(t, library); });
}
