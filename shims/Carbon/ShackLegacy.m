// Carbon Event Manager, Apple Events, File Manager (FSRef), Launch Services and Unicode Utilities calls that macOS games
// of 2016 still make next to their Cocoa code. iOS has none of them, and no other process to talk to: events never
// arrive, Apple Event handlers are accepted and never called, FSRefs are not modelled (a lookup fails as "not found").
// Feral Interactive's launcher (BioShock Remastered) polls ReceiveNextEvent and installs Apple Event handlers.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

enum { kUnimp = -4, kFnfErr = -43, kEventNotHandled = -9874, kEventLoopTimedOut = -9875, kAppNotFound = -10814 };
const CFStringRef kFSOperationBytesCompleteKey = CFSTR("kFSOperationBytesCompleteKey");
const CFStringRef kFSOperationTotalBytesKey = CFSTR("kFSOperationTotalBytesKey");
const CFStringRef kTISPropertyInputSourceIsASCIICapable = CFSTR("TISPropertyInputSourceIsASCIICapable");

// No events ever come from Carbon: wait out the timeout (a game blocks in here as its idle) and report it.
int32_t ReceiveNextEvent(UInt32 numTypes, const void *types, double timeout, Boolean pull, void **event) {
    if (event) *event = NULL;
    usleep((useconds_t)(fmin(timeout < 0 ? 0.05 : timeout, 0.05) * 1e6));
    return kEventLoopTimedOut;
}
void *GetEventDispatcherTarget(void) { return (void *)1; }
int32_t SendEventToEventTarget(void *event, void *target) { return kEventNotHandled; }
void ReleaseEvent(void *event) {}
UInt32 GetCurrentButtonState(void) { return 0; }
int32_t CopySymbolicHotKeys(CFArrayRef *hotKeys) { if (hotKeys) *hotKeys = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks); return 0; }
Boolean GetColor(int32_t where, const unsigned char *prompt, const void *inColor, void *outColor) { return false; }   // no colour picker

int16_t AEInstallEventHandler(UInt32 eventClass, UInt32 eventID, void *handler, long refcon, Boolean isSysHandler) { return 0; }
int16_t AERemoveEventHandler(UInt32 eventClass, UInt32 eventID, void *handler, Boolean isSysHandler) { return 0; }

// FSRefs are ShackCarbon.m's (a tag and an index into a table of paths); these calls build on them. ponytail: no volumes,
// no catalog info beyond a ref's parent, no alias resolution.
extern void ShackFSRefMake(NSString *path, void *out);
extern NSString *ShackFSRefPath(const void *ref);
int32_t FSCompareFSRefs(const void *a, const void *b) {
    NSString *pa = ShackFSRefPath(a), *pb = ShackFSRefPath(b);
    return pa && [pa isEqual:pb] ? 0 : -1417;   // errFSRefsDifferent
}
// Only the parent of an FSRef is answered (Feral's launcher walks up from its bundle); the rest of the record stays zero.
// macOS's FSCatalogInfo (CarbonCore Files.h, pack 2); m32 converts the i386 one (permissions 4 bytes shorter).
#pragma pack(push, 2)
typedef struct { UInt16 high; UInt32 low; UInt16 fraction; } ShackUTCDateTime;   // seconds since 1904, UTC
typedef struct {
    UInt16 nodeFlags; SInt16 volume; UInt32 parentDirID, nodeID; UInt8 sharingFlags, userPrivileges, reserved1, reserved2;
    ShackUTCDateTime createDate, contentModDate, attributeModDate, accessDate, backupDate;
    UInt32 userID, groupID; UInt8 permReserved, userAccess; UInt16 mode; void *fileSec;
    UInt8 finderInfo[16], extFinderInfo[16];
    UInt64 dataLogicalSize, dataPhysicalSize, rsrcLogicalSize, rsrcPhysicalSize;
    UInt32 valence, textEncodingHint;
} ShackCatalogInfo;
#pragma pack(pop)
_Static_assert(sizeof(ShackCatalogInfo) == 148, "FSCatalogInfo");
static ShackUTCDateTime ShackUTCDate(struct timespec t) {
    uint64_t s = (uint64_t)t.tv_sec + 2082844800;   // 1904-01-01 to 1970-01-01
    return (ShackUTCDateTime){ (UInt16)(s >> 32), (UInt32)s, (UInt16)((uint64_t)t.tv_nsec * 65536 / 1000000000) };
}
// From stat: a folder's valence is its item count, and games size their listings from it (Batman: valence + 2 records
// for readdir with . and ..; left untouched it overran the array). ponytail: every field is written whatever
// whichInfo asks for; no Finder info, resource forks or locks.
int32_t FSGetCatalogInfo(const void *ref, UInt32 whichInfo, void *info, void *name, void *spec, void *parentRef) {
    NSString *p = ShackFSRefPath(ref);
    if (!p) return -50;
    struct stat st, up;
    if (stat(p.fileSystemRepresentation, &st)) return kFnfErr;
    if (info) {
        ShackCatalogInfo *c = info; memset(c, 0, sizeof *c);
        BOOL dir = S_ISDIR(st.st_mode);
        c->nodeFlags = dir ? 0x10 : 0;   // kFSNodeIsDirectoryMask
        c->volume = -100;                // FSGetVolumeInfo's one volume
        c->parentDirID = stat(p.stringByDeletingLastPathComponent.fileSystemRepresentation, &up) ? 0 : (UInt32)up.st_ino;
        c->nodeID = (UInt32)st.st_ino;
        c->createDate = ShackUTCDate(st.st_birthtimespec);
        c->contentModDate = ShackUTCDate(st.st_mtimespec);
        c->attributeModDate = ShackUTCDate(st.st_ctimespec);
        c->accessDate = ShackUTCDate(st.st_atimespec);
        c->userID = st.st_uid; c->groupID = st.st_gid; c->mode = st.st_mode;
        if (!dir) { c->dataLogicalSize = (UInt64)st.st_size; c->dataPhysicalSize = (UInt64)st.st_blocks * 512; }
        else c->valence = (UInt32)[NSFileManager.defaultManager contentsOfDirectoryAtPath:p error:nil].count;
    }
    if (name) {   // HFSUniStr255
        NSString *n = p.lastPathComponent; UInt16 len = (UInt16)MIN(n.length, 255);
        ((UInt16 *)name)[0] = len; [n getCharacters:(unichar *)name + 1 range:NSMakeRange(0, len)];
    }
    if (parentRef) ShackFSRefMake(p.stringByDeletingLastPathComponent, parentRef);
    return 0;
}
// One volume, the app's data (what NSHomeDirectory sits on). Callers walk indexes 1, 2, ... until nsvErr: steamui's
// drive list did, and on kFnfErr it skipped and went on through all 4 billion indexes, a P core at 100% (2026-10-04).
int32_t FSGetVolumeInfo(int16_t vol, UInt32 index, int16_t *actual, UInt32 whichInfo, void *info, void *name, void *root) {
    enum { kNsvErr = -35 };
    if (vol == 0 && index != 1) return kNsvErr;   // kFSInvalidVolumeRefNum: by index
    if (actual) *actual = -100;   // ponytail: info and name left untouched; Steam passes NULL for both
    if (root) ShackFSRefMake(NSHomeDirectory(), root);
    return 0;
}
// Folder types by their four-character codes: the ones under the app's sandbox.
int16_t FSFindFolder(int16_t vol, UInt32 type, Boolean create, void *ref) {
    NSString *home = NSHomeDirectory(), *rel = nil;
    switch (type) {
    case 'asup': rel = @"Library/Application Support"; break;
    case 'docs': rel = @"Documents"; break;
    case 'pref': rel = @"Library/Preferences"; break;
    case 'cach': case 'pcac': rel = @"Library/Caches"; break;
    case 'temp': case 'ttmp': rel = @"tmp"; break;
    case 'desk': rel = @"Documents"; break;
    case 'fram':   // the system's (System.framework: Batman looks up free and ptrace there), else the user's own
        if (vol == -32767 || vol == -32766) { ShackFSRefMake(@"/System/Library/Frameworks", ref); return 0; }   // kOnAppropriateDisk, kSystemDomain
        rel = @"Library/Frameworks"; break;
    default: return kFnfErr;
    }
    NSString *path = [home stringByAppendingPathComponent:rel];
    if (create) [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    else if (![NSFileManager.defaultManager fileExistsAtPath:path]) return kFnfErr;
    ShackFSRefMake(path, ref);
    return 0;
}
static Boolean ShackFSRefIsDirectory(const void *ref) {
    BOOL dir = NO; NSString *p = ShackFSRefPath(ref);
    return p && [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir;
}
int32_t FSIsAliasFile(const void *ref, Boolean *isAlias, Boolean *isFolder) {   // no Finder aliases exist here
    if (!ShackFSRefPath(ref)) return -50;
    if (isAlias) *isAlias = false; if (isFolder) *isFolder = ShackFSRefIsDirectory(ref); return 0;
}
int32_t FSResolveAliasFile(void *ref, Boolean resolve, Boolean *isFolder, Boolean *wasAliased) {
    if (!ShackFSRefPath(ref)) return -50;
    if (isFolder) *isFolder = ShackFSRefIsDirectory(ref); if (wasAliased) *wasAliased = false; return 0;
}
int32_t FSPathMoveObjectToTrashSync(const char *path, char **target, UInt32 options) { if (target) *target = NULL; return kUnimp; }
void *FSFileOperationCreate(CFAllocatorRef alloc) { return NULL; }
int32_t FSFileOperationScheduleWithRunLoop(void *op, CFRunLoopRef loop, CFStringRef mode) { return kUnimp; }
int32_t FSFileOperationCancel(void *op) { return kUnimp; }

int32_t LSCopyDisplayNameForURL(CFURLRef url, CFStringRef *name) {
    if (name) *name = url ? CFURLCopyLastPathComponent(url) : NULL;
    return url ? 0 : -50;
}
int32_t LSCopyItemInfoForURL(CFURLRef url, UInt32 which, void *info) { if (info) memset(info, 0, 24); return 0; }   // LSItemInfoRecord
int32_t LSFindApplicationForInfo(UInt32 creator, CFStringRef bundleID, CFStringRef name, void *appRef, CFURLRef *appURL) {
    if (appURL) *appURL = NULL; return kAppNotFound;
}
// LongDateTime, as macOS keeps it: local seconds since 1904-01-01 (UTC plus the zone's offset at that moment), whole
// seconds down. Batman's file timestamps go through these; at 0, UE3's ini versions all said 2001-01-01 and it threw
// BmEngine.ini away every start, PhysX settings and all. ponytail: back from local time uses the offset at the local
// reading, an hour off only inside a daylight-saving change.
static const int64_t kLongDate2001 = 3061152000;   // 1904-01-01 to 2001-01-01
int32_t UCConvertCFAbsoluteTimeToLongDateTime(CFAbsoluteTime at, int64_t *ldt) {
    if (!ldt) return -50;   // paramErr
    CFTimeZoneRef tz = CFTimeZoneCopyDefault();
    *ldt = (int64_t)floor(at) + kLongDate2001 + (int64_t)CFTimeZoneGetSecondsFromGMT(tz, at);
    CFRelease(tz);
    return 0;
}
int32_t UCConvertLongDateTimeToCFAbsoluteTime(int64_t ldt, CFAbsoluteTime *at) {
    if (!at) return -50;
    CFTimeZoneRef tz = CFTimeZoneCopyDefault();
    CFAbsoluteTime local = (CFAbsoluteTime)(ldt - kLongDate2001);
    *at = local - CFTimeZoneGetSecondsFromGMT(tz, local);
    CFRelease(tz);
    return 0;
}

// HIToolbox's pointer position, in CG's global space (top-left origin, points): what a game that is not Retina-aware gets
// for kHICoordSpaceScreenPixel (1) and kHICoordSpace72DPIGlobal (2). It is NSEvent's mouseLocation (bottom-left
// origin), which touches and CGWarpMouseCursorPosition move. ponytail: the view and window spaces are refused (paramErr)
// until a game asks for them.
OSStatus HIGetMousePosition(uint32_t space, void *object, CGPoint *out) {
    if (!out || (space != 1 && space != 2)) return -50;
    id screen = ((id (*)(id, SEL))objc_msgSend)((id)NSClassFromString(@"NSScreen"), NSSelectorFromString(@"mainScreen"));
    CGRect frame = screen ? ((CGRect (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"frame")) : (CGRect){{0, 0}, {0, 0}};
    CGPoint p = ((CGPoint (*)(id, SEL))objc_msgSend)((id)NSClassFromString(@"NSEvent"), NSSelectorFromString(@"mouseLocation"));
    *out = (CGPoint){p.x, frame.size.height - p.y};
    return 0;
}

// Multiprocessing Services semaphores and critical regions (CarbonCore), which iOS lacks. Older engines hand work between
// threads with them (Batman: Arkham Asylum after a skipped cutscene): stubs that return at once left one thread spinning
// and the game thread waiting forever. Duration: 0 = no wait, 0x7FFFFFFF = forever, > 0 milliseconds, < 0 microseconds.
// A critical region can be entered again by the thread that holds it. ponytail: deleting one that a thread still waits on
// is not handled (Apple returns kMPDeletedErr to the waiter).
#import <pthread.h>
enum { kMPTimeoutErr = -29296, kMPInsufficientResourcesErr = -29298, kMPParamErr = -50, kMPForever = 0x7FFFFFFF };
typedef struct { pthread_mutex_t m; pthread_cond_t c; unsigned long count, max; } ShackMPSemaphore;
typedef struct { pthread_mutex_t m; pthread_cond_t c; pthread_t owner; unsigned long depth; } ShackMPRegion;

// With m held: waits on c until ready() or the Duration runs out; NO on a timeout.
static BOOL MPWait(pthread_cond_t *c, pthread_mutex_t *m, int32_t timeout, BOOL (^ready)(void)) {
    if (ready() || timeout == 0) return ready();
    struct timespec end; clock_gettime(CLOCK_REALTIME, &end);
    int64_t ns = timeout > 0 ? (int64_t)timeout * 1000000 : -(int64_t)timeout * 1000;
    end.tv_sec += ns / 1000000000; end.tv_nsec += ns % 1000000000;
    if (end.tv_nsec >= 1000000000) { end.tv_sec++; end.tv_nsec -= 1000000000; }
    while (!ready()) {
        if (timeout == kMPForever) pthread_cond_wait(c, m);
        else if (pthread_cond_timedwait(c, m, &end) == ETIMEDOUT) return ready();
    }
    return YES;
}

int32_t MPCreateSemaphore(unsigned long max, unsigned long initial, void **out) {
    if (!out || initial > max) return kMPParamErr;
    ShackMPSemaphore *s = calloc(1, sizeof *s);
    pthread_mutex_init(&s->m, NULL); pthread_cond_init(&s->c, NULL);
    s->count = initial; s->max = max;
    *out = s;
    return 0;
}
int32_t MPWaitOnSemaphore(void *sem, int32_t timeout) {
    ShackMPSemaphore *s = sem;
    if (!s) return kMPParamErr;
    pthread_mutex_lock(&s->m);
    BOOL got = MPWait(&s->c, &s->m, timeout, ^BOOL { return s->count > 0; });
    if (got) s->count--;
    pthread_mutex_unlock(&s->m);
    return got ? 0 : kMPTimeoutErr;
}
int32_t MPSignalSemaphore(void *sem) {
    ShackMPSemaphore *s = sem;
    if (!s) return kMPParamErr;
    pthread_mutex_lock(&s->m);
    BOOL room = s->count < s->max;
    if (room) { s->count++; pthread_cond_signal(&s->c); }
    pthread_mutex_unlock(&s->m);
    return room ? 0 : kMPInsufficientResourcesErr;
}
int32_t MPDeleteSemaphore(void *sem) {
    ShackMPSemaphore *s = sem;
    if (!s) return kMPParamErr;
    pthread_mutex_destroy(&s->m); pthread_cond_destroy(&s->c); free(s);
    return 0;
}

int32_t MPCreateCriticalRegion(void **out) {
    if (!out) return kMPParamErr;
    ShackMPRegion *r = calloc(1, sizeof *r);
    pthread_mutex_init(&r->m, NULL); pthread_cond_init(&r->c, NULL);
    *out = r;
    return 0;
}
int32_t MPEnterCriticalRegion(void *region, int32_t timeout) {
    ShackMPRegion *r = region;
    if (!r) return kMPParamErr;
    pthread_t me = pthread_self();
    pthread_mutex_lock(&r->m);
    BOOL in = MPWait(&r->c, &r->m, timeout, ^BOOL { return r->depth == 0 || pthread_equal(r->owner, me); });
    if (in) { r->owner = me; r->depth++; }
    pthread_mutex_unlock(&r->m);
    return in ? 0 : kMPTimeoutErr;
}
int32_t MPExitCriticalRegion(void *region) {
    ShackMPRegion *r = region;
    if (!r) return kMPParamErr;
    pthread_mutex_lock(&r->m);
    BOOL mine = r->depth && pthread_equal(r->owner, pthread_self());
    if (mine && --r->depth == 0) pthread_cond_signal(&r->c);
    pthread_mutex_unlock(&r->m);
    return mine ? 0 : kMPParamErr;
}
int32_t MPDeleteCriticalRegion(void *region) {
    ShackMPRegion *r = region;
    if (!r) return kMPParamErr;
    pthread_mutex_destroy(&r->m); pthread_cond_destroy(&r->c); free(r);
    return 0;
}
