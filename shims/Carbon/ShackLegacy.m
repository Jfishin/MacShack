// Carbon Event Manager, Apple Events, File Manager (FSRef), Launch Services and Unicode Utilities calls that macOS games
// of 2016 still make next to their Cocoa code. iOS has none of them, and no other process to talk to: events never
// arrive, Apple Event handlers are accepted and never called, FSRefs are not modelled (a lookup fails as "not found").
// Feral Interactive's launcher (BioShock Remastered) polls ReceiveNextEvent and installs Apple Event handlers.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <math.h>
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
int32_t FSGetCatalogInfo(const void *ref, UInt32 whichInfo, void *info, void *name, void *spec, void *parentRef) {
    NSString *p = ShackFSRefPath(ref);
    if (!p) return -50;
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
int32_t UCConvertCFAbsoluteTimeToLongDateTime(CFAbsoluteTime at, int64_t *ldt) { if (ldt) *ldt = 0; return kUnimp; }
int32_t UCConvertLongDateTimeToCFAbsoluteTime(int64_t ldt, CFAbsoluteTime *at) { if (at) *at = 0; return kUnimp; }
