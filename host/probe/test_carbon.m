// iOS simulator check of the Carbon shim (shims/Carbon/ShackLegacy.m; macOS's own Carbon headers clash with it):
// FSFindFolder (the system's Frameworks, the simulator app's home), FSGetCatalogInfo on a scratch folder, the LongDateTime converters against macOS's own answers:
//   xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc shims/Carbon/ShackLegacy.m \
//     shims/Carbon/ShackCarbon.m host/probe/test_carbon.m -framework Foundation -framework QuartzCore -o /tmp/t && xcrun simctl spawn booted /tmp/t
// expect `carbon ok`.
#import <Foundation/Foundation.h>
#import <stddef.h>
#import <sys/stat.h>
int16_t FSFindFolder(int16_t vol, UInt32 type, Boolean create, void *ref);
int32_t FSGetCatalogInfo(const void *ref, UInt32 whichInfo, void *info, void *name, void *spec, void *parentRef);
NSString *ShackFSRefPath(const void *ref);
void ShackFSRefMake(NSString *path, void *out);
// macOS's 64-bit FSCatalogInfo (CarbonCore Files.h, pack 2: 148 bytes, valence at 140; m32 converts the i386 one)
#pragma pack(push, 2)
typedef struct { UInt16 high; UInt32 low; UInt16 fraction; } UTC;
typedef struct {
    UInt16 nodeFlags; SInt16 volume; UInt32 parentDirID, nodeID; UInt8 sharing, privs, r1, r2;
    UTC createDate, contentModDate, attributeModDate, accessDate, backupDate;
    UInt32 userID, groupID; UInt8 r3, userAccess; UInt16 mode; void *fileSec;
    UInt8 finderInfo[16], extFinderInfo[16];
    UInt64 dataLogicalSize, dataPhysicalSize, rsrcLogicalSize, rsrcPhysicalSize;
    UInt32 valence, textEncodingHint;
} CatInfo;
#pragma pack(pop)
_Static_assert(sizeof(CatInfo) == 148 && offsetof(CatInfo, valence) == 140, "FSCatalogInfo");
int32_t UCConvertCFAbsoluteTimeToLongDateTime(CFAbsoluteTime at, int64_t *ldt);
int32_t UCConvertLongDateTimeToCFAbsoluteTime(int64_t ldt, CFAbsoluteTime *at);

int main(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        uint8_t ref[80] = {0};
        // Batman (Feral) looks up free and ptrace in System.framework: kOnAppropriateDisk, kFrameworksFolderType, create;
        // macOS answers /System/Library/Frameworks there (and for kSystemDomain), where iOS has System.framework too.
        BOOL dir = NO;
        for (int i = 0; i < 2; i++) {
            int16_t vol = i ? -32766 : -32767;
            int16_t e = FSFindFolder(vol, 'fram', 1, ref);
            NSString *path = e ? nil : ShackFSRefPath(ref);
            NSURL *fw = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:@"System.framework"]];
            CFBundleRef b = path ? CFBundleCreate(NULL, (__bridge CFURLRef)fw) : NULL;
            // ponytail: loading it is the phone's part (Batman's call log: CFBundleLoadExecutable 1); the simulator's
            // CFBundle checks the Mac's own System.framework, whose code is only in the Mac's dyld cache
            if (![path isEqual:@"/System/Library/Frameworks"] || !b ||
                ![(__bridge NSString *)CFBundleGetIdentifier(b) isEqual:@"com.apple.System"]) {
                fprintf(stderr, "FAIL: 'fram' vol %d -> %d %s bundle %p\n", vol, e, path.UTF8String ?: "(none)", b); return 1;
            }
            CFRelease(b);
        }
        // the user's own (kUserDomain): the app's home, made on request
        int16_t e = FSFindFolder(-32763, 'fram', 1, ref);
        NSString *path = e ? nil : ShackFSRefPath(ref);
        if (![path isEqual:[home stringByAppendingPathComponent:@"Library/Frameworks"]] ||
            ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir] || !dir) {
            fprintf(stderr, "FAIL: user 'fram' -> %d %s\n", e, path.UTF8String ?: "(none)"); return 1;
        }
        // FSGetCatalogInfo: Batman sizes a folder listing from the valence (items, not . and ..) plus 2, then writes one
        // 592-byte record per readdir entry; a valence of 0 overran the array (stop 3 on the iPhone, 2026-10-14)
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:[tmp stringByAppendingPathComponent:@"Maps"] withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *f in @[@"Core.u", @".DS_Store", @"Engine.u"])
            [@"hello" writeToFile:[tmp stringByAppendingPathComponent:f] atomically:NO encoding:NSUTF8StringEncoding error:nil];
        CatInfo ci; memset(&ci, 0xaa, sizeof ci);
        ShackFSRefMake(tmp, ref);
        e = FSGetCatalogInfo(ref, 0x2002, &ci, NULL, NULL, NULL);   // kFSCatInfoValence | kFSCatInfoNodeFlags
        if (e || ci.valence != 4 || !(ci.nodeFlags & 0x10)) {
            fprintf(stderr, "FAIL: folder -> %d valence %u flags %#x\n", e, ci.valence, ci.nodeFlags); return 1;
        }
        NSString *file = [tmp stringByAppendingPathComponent:@"Core.u"];
        struct stat st; stat(file.fileSystemRepresentation, &st);
        uint64_t mod = (uint64_t)st.st_mtimespec.tv_sec + 2082844800;   // UTCDateTime: seconds since 1904, UTC
        uint16_t uni[256] = {0};   // HFSUniStr255: length, then UTF-16
        ShackFSRefMake(file, ref);
        e = FSGetCatalogInfo(ref, 0x4062, &ci, uni, NULL, NULL);   // node flags, create and content dates, data sizes
        if (e || ci.nodeFlags & 0x10 || ci.dataLogicalSize != 5 || ci.contentModDate.high != mod >> 32 ||
            ci.contentModDate.low != (UInt32)mod || ci.fileSec || uni[0] != 6 || uni[1] != 'C' || uni[6] != 'u') {
            fprintf(stderr, "FAIL: file -> %d flags %#x size %llu mod %u:%u (want %llu) name %u\n", e, ci.nodeFlags,
                    ci.dataLogicalSize, ci.contentModDate.high, ci.contentModDate.low, mod, uni[0]); return 1;
        }
        ShackFSRefMake([tmp stringByAppendingPathComponent:@"gone"], ref);
        if ((e = FSGetCatalogInfo(ref, 0x2, &ci, NULL, NULL, NULL)) != -43) { fprintf(stderr, "FAIL: missing -> %d\n", e); return 1; }
        [fm removeItemAtPath:tmp error:nil];
        // LongDateTime: local seconds since 1904, whole seconds down; the values are macOS's own (CoreServices, New York
        // and Tokyo, 2026-10-14). Batman's file timestamps go through these (UE3's ini versions: all 2001-01-01 when 0).
        CFTimeZoneRef ny = CFTimeZoneCreateWithName(NULL, CFSTR("America/New_York"), true);
        CFTimeZoneSetDefault(ny);
        const struct { double at; int64_t ldt; double back; } cases[] = {
            {0, 3061134000, 0}, {1, 3061134001, 1}, {-1.5, 3061133998, -2}, {812490896.25, 3873628496, 812490896}};
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            int64_t l = 0; CFAbsoluteTime b = -1;
            if (UCConvertCFAbsoluteTimeToLongDateTime(cases[i].at, &l) || l != cases[i].ldt ||
                UCConvertLongDateTimeToCFAbsoluteTime(l, &b) || b != cases[i].back) {
                fprintf(stderr, "FAIL: %.2f -> %lld -> %.2f (want %lld, %.2f)\n", cases[i].at, (long long)l, b, (long long)cases[i].ldt, cases[i].back); return 1;
            }
        }
        CFTimeZoneSetDefault(CFTimeZoneCreateWithName(NULL, CFSTR("Asia/Tokyo"), true));
        int64_t tokyo = 0; UCConvertCFAbsoluteTimeToLongDateTime(0, &tokyo);
        if (tokyo != 3061184400) { fprintf(stderr, "FAIL: Tokyo %lld\n", (long long)tokyo); return 1; }
        puts("carbon ok");
    }
}
