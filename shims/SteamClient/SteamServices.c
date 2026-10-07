// libShackSteamClient: Launch Services and Carbon file calls whose generated stub (return 0) would read as success
// with nothing filled in, or NULL where Steam counts or releases the answer without a check.
#include <CoreFoundation/CoreFoundation.h>

// Login items ("Run Steam when my computer starts"): an empty list, so Steam's UI finds Steam is not one.
// ponytail: inserting does nothing; there is no login on iOS for it to start at.
typedef CFTypeRef LSSharedFileListRef, LSSharedFileListItemRef;
LSSharedFileListRef LSSharedFileListCreate(CFAllocatorRef alloc, CFStringRef listType, CFTypeRef options) {
    return CFArrayCreate(alloc, NULL, 0, &kCFTypeArrayCallBacks);   // a CF object Steam can release; never looked into
}
CFArrayRef LSSharedFileListCopySnapshot(LSSharedFileListRef list, uint32_t *seed) {
    if (seed) *seed = 1;
    return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}
LSSharedFileListItemRef LSSharedFileListInsertItemFSRef(LSSharedFileListRef list, LSSharedFileListItemRef after, CFStringRef name,
                                                        CFTypeRef icon, const void *fsRef, CFDictionaryRef set, CFArrayRef clear) { return NULL; }

// Carbon's HFS name (UInt16 length, then UTF-16) as a CFString.
CFStringRef FSCreateStringFromHFSUniStr(CFAllocatorRef alloc, const uint16_t *uniStr) {
    return uniStr ? CFStringCreateWithCharacters(alloc, uniStr + 1, uniStr[0] < 255 ? uniStr[0] : 255) : NULL;
}

// A file's kind ("Folder", "Application"): none, as an error the caller checks (paramErr), not success with no string.
int32_t LSCopyKindStringForRef(const void *fsRef, CFStringRef *outKind) { if (outKind) *outKind = NULL; return -50; }
