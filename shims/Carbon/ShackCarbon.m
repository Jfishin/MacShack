// Carbon (HIToolbox TIS/LM/events) and CoreServices (UCKeyTranslate, UpdateSystemActivity). Re-exports CoreServices,
// and libSystem for the libm symbols (exp2, modff, fegetenv...) that macOS's CoreServices umbrella re-exports.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

typedef struct __TISInputSource *TISInputSourceRef;
typedef struct UCKeyboardLayout UCKeyboardLayout;
typedef unsigned long UniCharCount;

const CFStringRef kTISPropertyUnicodeKeyLayoutData = CFSTR("TISPropertyUnicodeKeyLayoutData");
const CFStringRef kTISPropertyInputSourceID = CFSTR("TISPropertyInputSourceID");
const CFStringRef kTISPropertyInputSourceType = CFSTR("TISPropertyInputSourceType");
const CFStringRef kTISTypeKeyboardLayout = CFSTR("TISTypeKeyboardLayout");
const CFStringRef kTISTypeKeyboardInputMode = CFSTR("TISTypeKeyboardInputMode");
const CFStringRef kTISPropertyLocalizedName = CFSTR("TISPropertyLocalizedName");
extern const CFStringRef kTISPropertyInputSourceIsASCIICapable;   // ShackLegacy.m
const CFStringRef kTISPropertyInputSourceLanguages = CFSTR("TISPropertyInputSourceLanguages");
const CFStringRef kTISNotifySelectedKeyboardInputSourceChanged = CFSTR("TISNotifySelectedKeyboardInputSourceChanged");   // never posted

// ponytail: always the US layout; every "current source" is one opaque sentinel that only our functions read.
TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource(void) { return (TISInputSourceRef)CFRetain(CFSTR("ShackUSLayout")); }
TISInputSourceRef TISCopyCurrentKeyboardInputSource(void) { return TISCopyCurrentKeyboardLayoutInputSource(); }
TISInputSourceRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return TISCopyCurrentKeyboardLayoutInputSource(); }
TISInputSourceRef TISCopyCurrentASCIICapableKeyboardInputSource(void) { return TISCopyCurrentKeyboardLayoutInputSource(); }
// The one layout, whatever the filter (Godot 3 lists layouts for OS.get_keyboard_layout_*); selecting it is a no-op.
CFArrayRef TISCreateInputSourceList(CFDictionaryRef properties, Boolean includeAllInstalled) {
    const void *us = CFSTR("ShackUSLayout"); return CFArrayCreate(NULL, &us, 1, &kCFTypeArrayCallBacks);
}
OSStatus TISSelectInputSource(TISInputSourceRef source) { return noErr; }

void *TISGetInputSourceProperty(TISInputSourceRef source, CFStringRef key) {
    static CFDataRef layout; static dispatch_once_t once;
    if (key && CFEqual(key, kTISPropertyUnicodeKeyLayoutData)) {
        dispatch_once(&once, ^{ layout = CFDataCreate(NULL, (const UInt8 *)"SHCK", 4); });
        return (void *)layout;
    }
    if (key && CFEqual(key, kTISPropertyInputSourceIsASCIICapable)) return (void *)kCFBooleanTrue;
    if (key && CFEqual(key, kTISPropertyInputSourceID)) return (void *)CFSTR("com.apple.keylayout.US");
    if (key && CFEqual(key, kTISPropertyInputSourceType)) return (void *)kTISTypeKeyboardLayout;
    if (key && CFEqual(key, kTISPropertyLocalizedName)) return (void *)CFSTR("U.S.");
    if (key && CFEqual(key, kTISPropertyInputSourceLanguages)) {
        static CFArrayRef langs; static dispatch_once_t o;
        dispatch_once(&o, ^{ const void *en = CFSTR("en"); langs = CFArrayCreate(NULL, &en, 1, &kCFTypeArrayCallBacks); });
        return (void *)langs;
    }
    NSLog(@"[ShackCarbon] TISGetInputSourceProperty: unsupported key %@", (__bridge NSString *)key);
    return NULL;
}

UInt8 LMGetKbdType(void) { return 40; }   // ANSI
UInt8 LMGetKbdLast(void) { return 40; }
// ponytail: no polled keyboard state; keys arrive as NSEvents. Fill from ShackKeyMap if a game polls for input.
UInt32 GetCurrentKeyModifiers(void) { return 0; }
void GetKeys(UInt32 keys[4]) { memset(keys, 0, 16); }
double GetCurrentEventTime(void) { return CACurrentMediaTime(); }   // EventTime: seconds since boot, the NSEvent timestamp base
OSErr UpdateSystemActivity(UInt8 activity) { return noErr; }   // ponytail: idle-sleep is the host's business

// Index = macOS virtual keycode (kVK_ANSI_A = 0 ... kVK_ANSI_Grave = 50, kVK_Delete = 51 -> backspace 0x08 as the US uchr gives, 52 unused, kVK_Escape = 53).
static const char kPlain[]   = "asdfhgzxcv\0bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `\b\0\x1b";
static const char kShifted[] = "ASDFHGZXCV\0BQWERYT!@#$^%+(&_*)}OU{IP\rLJ\"K:|<?NM>\t ~\b\0\x1b";
_Static_assert(sizeof kPlain == 55 && sizeof kShifted == 55, "keycode tables must cover 0..53");

OSStatus UCKeyTranslate(const UCKeyboardLayout *keyLayoutPtr, UInt16 virtualKeyCode, UInt16 keyAction,
                        UInt32 modifierKeyState, UInt32 keyboardType, OptionBits keyTranslateOptions,
                        UInt32 *deadKeyState, UniCharCount maxStringLength, UniCharCount *actualStringLength,
                        UniChar unicodeString[]) {
    if (!actualStringLength) return -50;   // paramErr (MacErrors.h, absent on iOS)
    BOOL shift = (modifierKeyState & (1 << 1)) != 0;   // caller passes (modifiers >> 8) & 0xFF; shiftKey = 1 << 9
    UniChar c = 0;
    if (virtualKeyCode < 54) c = (unsigned char)(shift ? kShifted : kPlain)[virtualKeyCode];
    else if (virtualKeyCode >= 123 && virtualKeyCode <= 126) {   // left, right, down, up: what the US 'uchr' yields
        static const UniChar arrows[] = {0x1C, 0x1D, 0x1F, 0x1E};
        c = arrows[virtualKeyCode - 123];
    }
    *actualStringLength = (c && maxStringLength) ? 1 : 0;
    if (*actualStringLength) unicodeString[0] = c;
    if (deadKeyState) *deadKeyState = 0;
    return noErr;
}

// Launch Services (CoreServices): opening a URL goes to iOS; registering URL handlers has no iOS equivalent.
OSStatus LSOpenCFURLRef(CFURLRef url, CFURLRef *launchedURL) {
    if (launchedURL) *launchedURL = NULL;
    if (!url) return -50;   // paramErr
    NSURL *u = [(__bridge NSURL *)url copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        id app = [NSClassFromString(@"UIApplication") valueForKey:@"sharedApplication"];
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(app, NSSelectorFromString(@"openURL:options:completionHandler:"), u, @{}, nil);
    });
    return noErr;
}
OSStatus LSRegisterURL(CFURLRef url, Boolean update) { return noErr; }
OSStatus LSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundleID) { return noErr; }
UInt32 KBGetLayoutType(SInt16 keyboardType) { return 'ANSI'; }   // kKeyboardANSI, matching LMGetKbdType

// Gestalt (CoreServices): Unity 2021.3's UnityPlayer asks it for the OS version. Same numbers as NSProcessInfo.
OSErr Gestalt(OSType selector, SInt32 *response) {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    switch (selector) {
    case 'sys1': *response = (SInt32)v.majorVersion; return noErr;
    case 'sys2': *response = (SInt32)v.minorVersion; return noErr;
    case 'sys3': *response = (SInt32)v.patchVersion; return noErr;
    case 'sysv': *response = 0x1090; return noErr;   // BCD 10.9.0: Apple's own cap for 10.10 and later
    case 'ramm': *response = (SInt32)(NSProcessInfo.processInfo.physicalMemory >> 20); return noErr;
    }
    NSLog(@"[ShackCarbon] Gestalt('%c%c%c%c') unsupported", (char)(selector >> 24), (char)(selector >> 16), (char)(selector >> 8), (char)selector);
    return -5551;   // gestaltUndefSelectorErr
}

// Presentation mode (menu bar and Dock hiding for full screen): a game on iOS is always full screen. Aragami (Unity
// 2017) sets it before its first frame. kUIModeNormal = 0.
static UInt32 gUIMode, gUIOptions;
OSStatus SetSystemUIMode(UInt32 mode, UInt32 options) { gUIMode = mode; gUIOptions = options; return noErr; }
void GetSystemUIMode(UInt32 *mode, UInt32 *options) { if (mode) *mode = gUIMode; if (options) *options = gUIOptions; }

// Carbon Event Manager (Aragami's Unity 2017 installs handlers on the application target): nothing on iOS delivers
// Carbon events, so installs succeed and handlers never run. The target and handler refs are opaque tokens.
typedef struct OpaqueEventTargetRef *EventTargetRef;
typedef struct OpaqueEventHandlerRef *EventHandlerRef;
typedef struct OpaqueEventRef *EventRef;
EventTargetRef GetApplicationEventTarget(void) { return (EventTargetRef)(uintptr_t)0x5348; }
OSStatus InstallEventHandler(EventTargetRef target, void *handler, UInt32 numTypes, const void *types, void *userData, EventHandlerRef *outRef) {
    if (outRef) *outRef = (EventHandlerRef)(uintptr_t)0x5349;
    return noErr;
}
OSStatus RemoveEventHandler(EventHandlerRef ref) { return noErr; }
UInt32 GetEventKind(EventRef event) { return 0; }
OSStatus GetEventParameter(EventRef event, UInt32 name, UInt32 type, UInt32 *outType, UInt32 size, UInt32 *outSize, void *data) {
    return -9870;   // eventParameterNotFoundErr
}

// CoreServices File Manager, still used by CoronaCards (Solar2D) for paths. An FSRef is 80 opaque bytes on macOS; this one
// holds a magic and an index into a table of the paths handed out (never freed: a game makes a handful).
typedef struct { UInt8 hidden[80]; } ShackFSRef;
static NSMutableArray<NSString *> *gFSPaths;
OSStatus FSPathMakeRef(const UInt8 *path, ShackFSRef *ref, Boolean *isDirectory) {
    if (!path || !ref) return -50;   // paramErr
    NSString *p = [NSString stringWithUTF8String:(const char *)path];
    BOOL dir = NO;
    if (!p.length || ![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir]) return -43;   // fnfErr
    @synchronized([NSFileManager class]) {
        if (!gFSPaths) gFSPaths = [NSMutableArray array];
        [gFSPaths addObject:p.stringByStandardizingPath];
        memset(ref, 0, sizeof *ref);
        memcpy(ref->hidden, "SHFS", 4);
        uint32_t index = (uint32_t)gFSPaths.count - 1;
        memcpy(ref->hidden + 4, &index, 4);
    }
    if (isDirectory) *isDirectory = dir;
    return noErr;
}
OSStatus FSRefMakePath(const ShackFSRef *ref, UInt8 *path, UInt32 maxPathSize) {
    if (!ref || !path || memcmp(ref->hidden, "SHFS", 4)) return -50;
    uint32_t index; memcpy(&index, ref->hidden + 4, 4);
    NSString *p;
    @synchronized([NSFileManager class]) { p = index < gFSPaths.count ? gFSPaths[index] : nil; }
    const char *c = p.fileSystemRepresentation;
    if (!c || strlen(c) + 1 > maxPathSize) return -50;
    strcpy((char *)path, c);
    return noErr;
}
// The same refs for the other shims and the CFURL hooks (ShackHooks.m): make one from a path, read the path back.
void ShackFSRefMake(NSString *path, void *out) {
    ShackFSRef *ref = out; memset(ref, 0, sizeof *ref);
    @synchronized([NSFileManager class]) {
        if (!gFSPaths) gFSPaths = [NSMutableArray array];
        NSUInteger i = [gFSPaths indexOfObject:path];
        if (i == NSNotFound) { [gFSPaths addObject:path]; i = gFSPaths.count - 1; }
        memcpy(ref->hidden, "SHFS", 4);
        uint32_t index = (uint32_t)i; memcpy(ref->hidden + 4, &index, 4);
    }
}
NSString *ShackFSRefPath(const void *r) {
    const ShackFSRef *ref = r;
    if (!ref || memcmp(ref->hidden, "SHFS", 4)) return nil;
    uint32_t index; memcpy(&index, ref->hidden + 4, 4);
    @synchronized([NSFileManager class]) { return index < gFSPaths.count ? gFSPaths[index] : nil; }
}
// "No default application": the callers open the URL themselves or skip it.
CFURLRef LSCopyDefaultApplicationURLForURL(CFURLRef url, uint32_t roles, CFErrorRef *error) { if (error) *error = NULL; return NULL; }
