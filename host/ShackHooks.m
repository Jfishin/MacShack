#import "ShackCFXML.h"
#import "ShackHooks.h"
#import "vendor/fishhook.h"
#import "ShackSwap.h"
#import "ShackTrapJIT.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "ShackMetal.h"
#import <IOKit/IOKitLib.h>
#import <mach-o/dyld.h>
#import <crt_externs.h>
// libproc.h is absent from the iOS SDK; proc_pidpath is only rebound by name, so no prototype needed.
#import <unistd.h>
#import <dlfcn.h>
#import <pthread.h>
#import <execinfo.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>

static NSBundle *gGuestBundle;
static char gGuestExec[PATH_MAX];
static CFBundleRef gGuestCFBundle;
// A second guest beside the first: a game the Steam client starts runs in-process with Steam (ShackSteamClient.m). Its
// code (images under its code root) and its main thread see the game's bundle, executable, code, defaults and exit;
// everything else keeps the first guest's. Inert until ShackHooksAddGuest (code empty).
static struct { NSBundle *bundle; CFBundleRef cfBundle; char exec[PATH_MAX], root[PATH_MAX], code[PATH_MAX];
                NSUserDefaults *defaults; CFStringRef prefsID; void (^ended)(int); BOOL translated; } gSecond;
static __thread BOOL tSecondThread;
static BOOL isSecondCaller(const void *pc);
static BOOL redirectSecondGuest(int sig, void *ucv);
static int (*orig_NSGetExecutablePath)(char *, uint32_t *);
static int (*orig_proc_pidpath)(int, void *, uint32_t);

static int shack_NSGetExecutablePath(char *buf, uint32_t *size) {
    const char *exe = isSecondCaller(__builtin_return_address(0)) ? gSecond.exec : gGuestExec;
    size_t n = strlen(exe) + 1;
    if (*size < n) { *size = (uint32_t)n; return -1; }
    memcpy(buf, exe, n); return 0;
}
static int shack_proc_pidpath(int pid, void *buf, uint32_t size) {
    if (pid != getpid()) return orig_proc_pidpath(pid, buf, size);
    return (int)strlcpy(buf, isSecondCaller(__builtin_return_address(0)) ? gSecond.exec : gGuestExec, size);
}
static CFBundleRef shack_CFBundleGetMainBundle(void) { return isSecondCaller(__builtin_return_address(0)) ? gSecond.cfBundle : gGuestCFBundle; }

// Unity's desktop player unconditionally releases this Copy result. The iOS
// SystemConfiguration export returns NULL because computer names are macOS-only.
static CFStringRef (*orig_SCDynamicStoreCopyComputerName)(CFTypeRef, CFStringEncoding *);
static CFStringRef shack_SCDynamicStoreCopyComputerName(CFTypeRef store, CFStringEncoding *encoding) {
    CFStringRef name = orig_SCDynamicStoreCopyComputerName ? orig_SCDynamicStoreCopyComputerName(store, encoding) : NULL;
    if (name) return name; // Preserve the original Copy ownership.
    if (encoding) *encoding = kCFStringEncodingUTF8;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fprintf(stderr, "[MacShack] desktop computer name unavailable; using iOS device name\n"); });
    return CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)(UIDevice.currentDevice.name ?: @"iPhone"));
}

// Guest exits are logged with a backtrace (image+offset, for atos -l against the Mac binary), then proceed.
static void (*orig_exit)(int), (*orig__exit)(int), (*orig__Exit)(int), (*orig_abort)(void);
static void logExit(const char *what, int code) {
    void *f[32]; int n = backtrace(f, 32);
    fprintf(stderr, "[MacShack] %s(%d) from:\n", what, code);
    for (int i = 1; i < n; i++) {
        Dl_info d = {0}; dladdr(f[i], &d);
        const char *slash = d.dli_fname ? strrchr(d.dli_fname, '/') : NULL;
        const char *img = slash ? slash + 1 : (d.dli_fname ?: "?");
        fprintf(stderr, "  %2d %-24s +0x%lx  %s + %ld\n", i, img, (unsigned long)((char *)f[i] - (char *)d.dli_fbase),
                d.dli_sname ?: "?", (long)((char *)f[i] - (char *)d.dli_saddr));
    }
    fflush(stdout); fflush(stderr);
}
// Guest fault handlers (Mono's, Unity's) are wrapped so the first few faults are logged with pc/lr/frame chain as
// image+offset before the guest's handler runs (Unity's can hang while it symbolizes). ponytail: Mono also takes
// SIGSEGV for null checks, so only the first 4 are logged.
#include <signal.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
static int (*orig_sigaction)(int, const struct sigaction *, struct sigaction *);
static struct sigaction gGuestAct[NSIG];
static void logAddr(const char *tag, uintptr_t a) {
    Dl_info d = {0}; dladdr((void *)a, &d);
    const char *slash = d.dli_fname ? strrchr(d.dli_fname, '/') : NULL;
    fprintf(stderr, "  %-4s %-24s +0x%lx  %s\n", tag, slash ? slash + 1 : "?", (unsigned long)(a - (uintptr_t)d.dli_fbase), d.dli_sname ?: "?");
}
static void shack_fault(int sig, siginfo_t *si, void *ucv) {
    if ((sig == SIGBUS || sig == SIGSEGV) && ShackTrapJITFault(si, ucv)) return;   // stock Mono writing its code
    BOOL fatal = sig == SIGTRAP || sig == SIGILL;   // a crash, never a fault a handler fixes (a trap is a failed check)
    static _Atomic int logged;
    if (logged++ < 4) {
        ucontext_t *uc = ucv; __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
        fprintf(stderr, "[MacShack] signal %d code %d addr %p\n", sig, si->si_code, si->si_addr);
        // Stack bounds (a thread near its bottom means overflow: iOS gives the main thread 1 MB, macOS 8 MB) and the
        // faulting instructions, so a crash in an unsymbolicated system library can still be disassembled offline.
        pthread_t self = pthread_self(); uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self), size = pthread_get_stacksize_np(self);
        uintptr_t sp = (uintptr_t)__darwin_arm_thread_state64_get_sp(*ss), pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(*ss) & 0x0000FFFFFFFFFFFFull;
        fprintf(stderr, "[MacShack] %s thread sp=%p stack [%p, %p) (%zu KB left)\n", pthread_main_np() ? "main" : "other",
                (void *)sp, (void *)(top - size), (void *)top, sp > top - size ? (size_t)(sp - (top - size)) >> 10 : 0);
        fprintf(stderr, "[MacShack] code at pc-16:"); for (int i = -4; i < 4; i++) fprintf(stderr, " %08x", ((const uint32_t *)pc)[i]); fprintf(stderr, "\n");
        fprintf(stderr, "[MacShack] x0=%llx x1=%llx x2=%llx x3=%llx x8=%llx\n", ss->__x[0], ss->__x[1], ss->__x[2], ss->__x[3], ss->__x[8]);
        logAddr("pc", (uintptr_t)__darwin_arm_thread_state64_get_pc(*ss)); logAddr("lr", (uintptr_t)__darwin_arm_thread_state64_get_lr(*ss));
        uintptr_t *fp = (uintptr_t *)__darwin_arm_thread_state64_get_fp(*ss);
        for (int i = 0; i < 24 && fp && ((uintptr_t)fp & 7) == 0; i++, fp = (uintptr_t *)fp[0]) logAddr("fp", fp[1] & 0x0000FFFFFFFFFFFFull);
    }
    if (fatal && redirectSecondGuest(sig, ucv)) return;
    struct sigaction *g = &gGuestAct[sig];
    if (g->sa_flags & SA_SIGINFO) g->sa_sigaction(sig, si, ucv);
    else if (g->sa_handler != SIG_DFL && g->sa_handler != SIG_IGN) g->sa_handler(sig);
    else if (redirectSecondGuest(sig, ucv)) return;
    else { struct sigaction dfl = {0}; orig_sigaction(sig, &dfl, NULL); }   // no guest handler: re-fault into the default
}
static int shack_sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    // AArchX (Intel games) owns the process's fault handling: it installs its handler with SA_NODEFER and its own
    // alternate stack and recovers faults it takes on purpose, none of which survives running under shack_fault.
    Dl_info caller;
    if (dladdr(__builtin_return_address(0), &caller) && caller.dli_fname && strstr(caller.dli_fname, "/libOcerz.dylib"))
        return orig_sigaction(sig, act, old);
    // SIGSEGV/SIGBUS keep shack_fault installed for the whole run (ShackHooksInstall): the guest's handler is only
    // recorded, and a guest asking for the previous handler gets the previous guest's, so Mono chains to Unity's
    // instead of back into shack_fault.
    if (sig == SIGSEGV || sig == SIGBUS) {
        struct sigaction prev = gGuestAct[sig];
        if (act) gGuestAct[sig] = *act;
        if (old) *old = prev;
        return 0;
    }
    if (act && (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGTRAP || sig == SIGFPE) && act->sa_handler != SIG_DFL
        && act->sa_handler != SIG_IGN && act->sa_sigaction != shack_fault) {
        gGuestAct[sig] = *act;
        struct sigaction w = *act; w.sa_sigaction = shack_fault; w.sa_flags |= SA_SIGINFO;
        return orig_sigaction(sig, &w, old);
    }
    return orig_sigaction(sig, act, old);
}
// signal() calls sigaction inside libsystem, past the rebinding: route it through shack_sigaction (Factorio).
static void (*shack_signal(int sig, void (*handler)(int)))(int) {
    struct sigaction act = {0}, old = {0}; act.sa_handler = handler; act.sa_flags = SA_RESTART;   // as libc's signal()
    return shack_sigaction(sig, &act, &old) ? SIG_ERR : old.sa_handler;
}

// A game ending (exit/_exit/_Exit, or main returning) must not end MacShack: the host returns to MacShack's own screen and relaunches
// itself for the next game (one game per process). The calling thread never returns: a guest thread parks, the main
// thread keeps running its run loop so the UI stays alive. MacShack's own exits use ShackExitProcess.
void ShackGuestEnded(int code) {
    fflush(stdout); fflush(stderr);
    // The process lives on, so the game's audio would keep playing (the system still calls its callbacks).
    void (*stopAudio)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "ShackAudioStopAll");   // libShackAudioToolbox
    if (stopAudio) stopAudio();
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"ShackGuestExited" object:nil userInfo:@{@"code": @(code)}];
    });
}
static void endThisThread(void) {
    if (pthread_main_np()) for (;;) CFRunLoopRun();
    for (;;) pause();
}
// The second guest's end goes to whoever started it (Steam hears its child exit); the first guest's ends MacShack's run.
static void guestEnded(int c, const void *pc) { if (gSecond.ended && isSecondCaller(pc)) gSecond.ended(c); else ShackGuestEnded(c); }
static void shack_exit(int c) { logExit("exit", c); guestEnded(c, __builtin_return_address(0)); endThisThread(); __builtin_unreachable(); }
static void shack__exit(int c) { logExit("_exit", c); guestEnded(c, __builtin_return_address(0)); endThisThread(); __builtin_unreachable(); }
static void shack__Exit(int c) { logExit("_Exit", c); guestEnded(c, __builtin_return_address(0)); endThisThread(); __builtin_unreachable(); }
void ShackExitProcess(int code) { if (orig_exit) orig_exit(code); exit(code); }
static void shack_abort(void) {
    logExit("abort", 0);
    if (gSecond.ended && isSecondCaller(__builtin_return_address(0))) { gSecond.ended(134); endThisThread(); }   // the game, not MacShack
    orig_abort(); __builtin_unreachable();
}
// A second guest that crashes ends alone (a game the Steam client started must not take Steam down): the crashed thread
// leaves the signal handler into secondGuestCrashed, which reports the game's end and parks the thread. GameMaker's
// quit double-frees with pads connected, and Chromium's allocator (the process's malloc in single-process mode) traps.
static void secondGuestCrashed(int sig) {
    fprintf(stderr, "[MacShack] the second guest crashed (signal %d): it ends, MacShack and the first guest go on\n", sig);
    gSecond.ended(128 + sig);
    endThisThread();
}
static BOOL redirectSecondGuest(int sig, void *ucv) {
    if (!*gSecond.code || !gSecond.ended) return NO;
    ucontext_t *uc = ucv; __typeof__(uc->uc_mcontext->__ss) *ss = &uc->uc_mcontext->__ss;
    if (!tSecondThread && !isSecondCaller((void *)((uintptr_t)__darwin_arm_thread_state64_get_pc(*ss) & 0x0000FFFFFFFFFFFFull))) return NO;
    __darwin_arm_thread_state64_set_sp(*ss, ((uintptr_t)__darwin_arm_thread_state64_get_sp(*ss) - 1024) & ~(uintptr_t)15);
    __darwin_arm_thread_state64_set_pc_fptr(*ss, secondGuestCrashed);
    ss->__x[0] = (uint64_t)sig;
    return YES;
}

// ponytail: iOS APFS is case-sensitive; UE4 refuses to start on such a volume. Its pak lookups are case-insensitive
// internally, so claim case-insensitivity; a loose file referenced with the wrong case shows up as a missing file.
@implementation NSURL (Shack)
- (BOOL)shack_getResourceValue:(out id *)v forKey:(NSURLResourceKey)k error:(out NSError **)e {
    if ([k isEqualToString:NSURLVolumeSupportsCaseSensitiveNamesKey]) { if (v) *v = @NO; return YES; }
    return [self shack_getResourceValue:v forKey:k error:e];
}
@end

@implementation NSBundle (Shack)
+ (NSBundle *)shack_mainBundle { return isSecondCaller(__builtin_return_address(0)) ? gSecond.bundle : gGuestBundle ?: [self shack_mainBundle]; }
// iOS CFBundle does not resolve a macOS Contents/MacOS executable: executablePath is nil without this.
- (NSString *)shack_executablePath {
    return self == gGuestBundle ? @(gGuestExec) : self == gSecond.bundle ? @(gSecond.exec) : [self shack_executablePath];
}
- (NSURL *)shack_executableURL {
    return self == gGuestBundle || self == gSecond.bundle ? [NSURL fileURLWithPath:self.executablePath] : [self shack_executableURL];
}
@end

// A free developer account has no app-group entitlement, so iOS answers nil and a game that then builds a path from the
// URL crashes (Feral's engine: CFURLCopyFileSystemPath(NULL) right after this call). macOS keeps a group container
// under ~/Library/Group Containers/<id>; give the guest that one, created on demand, inside its own sandbox.
@implementation NSFileManager (Shack)
- (NSURL *)shack_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *url = [self shack_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    if (url || !gGuestBundle || !groupIdentifier.length) return url;
    url = [[NSURL fileURLWithPath:NSHomeDirectory()] URLByAppendingPathComponent:[@"Library/Group Containers" stringByAppendingPathComponent:groupIdentifier] isDirectory:YES];
    [self createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    return url;
}
@end

// Arguments: CoreFoundation read MacShack's argv when MacShack started, so NSProcessInfo.arguments stays MacShack's.
// Both the native loader and AArchX point _NSGetArgv at the game's argv; Unity 2019 reads its switches
// (-force-metal) from NSProcessInfo, Unity 2018 from argv. Until something repoints argv, the host's answer stands.
static char **gHostArgv;
@implementation NSProcessInfo (Shack)
- (NSArray<NSString *> *)shack_arguments {
    char **v = *_NSGetArgv();
    int c = *_NSGetArgc();
    if (v == gHostArgv || !v || c <= 0) return [self shack_arguments];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)c];
    for (int i = 0; i < c; i++) if (v[i]) [a addObject:@(v[i])];
    return a;
}
@end

// Preferences: on macOS each game's standard defaults are its own bundle id's domain; here they were MacShack's, one
// domain for every game (Valheim's `language` = "English" made Soulstone Survivors' `new CultureInfo` throw at boot).
// Guest code (images under Guests/, as ShackWatch tells them) gets the game's domain; the host keeps its own.
// ponytail: callers are told apart by return address, so a guest reaching defaults only through a system library
// (Swift's UserDefaults overlay) still lands in MacShack's domain. Only the reads Unity imports are hooked on the
// CFPreferences side; add CFPreferencesSetAppValue/AppSynchronize when a game writes that way.
static NSUserDefaults *gGuestDefaults;
static CFStringRef gGuestPrefsID;
// libOcerz (AArchX) calls these only on behalf of an Intel game, whose own code is data it translates.
static int (*o_dladdr)(const void *, Dl_info *);   // dladdr is rebound in the host too: the original, once hooks are in
static BOOL isGuestCaller(const void *pc) {
    Dl_info d;
    return (o_dladdr ?: dladdr)(pc, &d) && d.dli_fname && (strstr(d.dli_fname, "/Guests/") || strstr(d.dli_fname, "/libOcerz.dylib"));
}
// path under root, either spelling of the container (dyld and realpath keep /private/var, NSString drops it).
static BOOL underRoot(const char *path, const char *root) {
    size_t n = strlen(root);
    if (!n) return NO;
    if (!strncmp(path, root, n)) return path[n] == '/' || !path[n];
    if (!strncmp(root, "/private/", 9) && !strncmp(path, root + 8, n - 8)) return path[n - 8] == '/' || !path[n - 8];
    return NO;
}
// An Intel second guest calls through libOcerz or straight from AArchX's JIT pool (no image): Steam never runs there.
static BOOL isSecondCaller(const void *pc) {
    if (!*gSecond.code) return NO;
    if (tSecondThread) return YES;
    Dl_info d;
    if (!(o_dladdr ?: dladdr)(pc, &d) || !d.dli_fname) return gSecond.translated;
    return underRoot(d.dli_fname, gSecond.code) || (gSecond.translated && strstr(d.dli_fname, "/libOcerz.dylib"));
}
@implementation NSUserDefaults (Shack)
+ (NSUserDefaults *)shack_standardUserDefaults {
    const void *pc = __builtin_return_address(0);
    if (gSecond.defaults && isSecondCaller(pc)) return gSecond.defaults;
    return gGuestDefaults && isGuestCaller(pc) ? gGuestDefaults : [self shack_standardUserDefaults];
}
@end
// A Mac game starts in a fresh process, so GameController announces every pad (mouse, keyboard) after the game has
// subscribed. Here they connected to MacShack before the game ran, and a game that builds its pad list only from
// GCControllerDidConnectNotification (Cyberpunk 2077: it never asks +controllers) saw none. A guest subscribing to a
// connect notification is told about each device already connected, once a layer that first drew after the game
// started has drawn (the game's own: a Mac game hears of its pads only after it has started; Cyberpunk's handler writes
// to its input system and crashed when told 40 ms in; Big Picture's layers drew before), on the subscribing thread's run
// loop (the game's main thread, which is not UIKit's here).
// ponytail: a game that also lists +controllers hears of those pads twice (SDL ignores a pad it already has).
static NSArray *connectedDevices(NSString *name) {
    if ([name isEqualToString:GCControllerDidConnectNotification]) return GCController.controllers;   // with the touch pad
    if ([name isEqualToString:GCMouseDidConnectNotification]) return GCMouse.mice;
    if ([name isEqualToString:GCKeyboardDidConnectNotification]) return GCKeyboard.coalescedKeyboard ? @[GCKeyboard.coalescedKeyboard] : @[];
    return nil;
}
static CFTimeInterval gGuestStarted, gNewLayerDrew;   // main thread only
static NSMutableArray<dispatch_block_t> *gAfterGameFrame;
static void noteGuestStarted(void) { dispatch_async(dispatch_get_main_queue(), ^{ gGuestStarted = CACurrentMediaTime(); }); }
static void replayConnected(NSString *name, void (^tell)(NSNotification *)) {
    CFRunLoopRef loop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    dispatch_block_t go = ^{
        CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{
            for (id device in connectedDevices(name)) tell([NSNotification notificationWithName:name object:device]);
        });
        CFRunLoopWakeUp(loop);
        CFRelease(loop);
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gNewLayerDrew > gGuestStarted) go(); else [gAfterGameFrame addObject:go];
    });
}
@implementation NSNotificationCenter (Shack)
- (void)shack_addObserver:(id)observer selector:(SEL)sel name:(NSNotificationName)name object:(id)object {
    [self shack_addObserver:observer selector:sel name:name object:object];
    if (object || !connectedDevices(name) || !isGuestCaller(__builtin_return_address(0))) return;
    __weak id weakObserver = observer;
    replayConnected(name, ^(NSNotification *n) {
        id o = weakObserver;
        if (!o) return;
        NSLog(@"[MacShack] %@ already connected: told %@", n.object, NSStringFromClass([o class]));
        ((void (*)(id, SEL, NSNotification *))objc_msgSend)(o, sel, n);
    });
}
- (id)shack_addObserverForName:(NSNotificationName)name object:(id)object queue:(NSOperationQueue *)queue usingBlock:(void (^)(NSNotification *))block {
    id token = [self shack_addObserverForName:name object:object queue:queue usingBlock:block];
    if (object || !connectedDevices(name) || !isGuestCaller(__builtin_return_address(0))) return token;
    replayConnected(name, ^(NSNotification *n) { if (queue) [queue addOperationWithBlock:^{ block(n); }]; else block(n); });
    return token;
}
@end
static CFStringRef guestApp(CFStringRef app, const void *pc) {
    if (!app || !CFEqual(app, kCFPreferencesCurrentApplication)) return app;
    if (gSecond.prefsID && isSecondCaller(pc)) return gSecond.prefsID;
    return gGuestPrefsID && isGuestCaller(pc) ? gGuestPrefsID : app;
}
static CFPropertyListRef (*orig_CFPreferencesCopyAppValue)(CFStringRef, CFStringRef);
static Boolean (*orig_CFPreferencesGetAppBooleanValue)(CFStringRef, CFStringRef, Boolean *);
static CFIndex (*orig_CFPreferencesGetAppIntegerValue)(CFStringRef, CFStringRef, Boolean *);
static CFPropertyListRef shack_CFPreferencesCopyAppValue(CFStringRef k, CFStringRef app) { return orig_CFPreferencesCopyAppValue(k, guestApp(app, __builtin_return_address(0))); }
static Boolean shack_CFPreferencesGetAppBooleanValue(CFStringRef k, CFStringRef app, Boolean *ok) { return orig_CFPreferencesGetAppBooleanValue(k, guestApp(app, __builtin_return_address(0)), ok); }
static CFIndex shack_CFPreferencesGetAppIntegerValue(CFStringRef k, CFStringRef app, Boolean *ok) { return orig_CFPreferencesGetAppIntegerValue(k, guestApp(app, __builtin_return_address(0)), ok); }

// UE4's Apple Silicon GPU survey (FMacPlatformGPUManager) walks IOKit: AppleARMIODevice entries whose device_type
// starts with "sgx", then their IOAccelerator child's properties. The iOS sandbox hides those, the GPU list comes
// back empty and the Metal RHI indexes past it. ponytail: a fake two-node registry (GPU node + accelerator child)
// answered by hooks; every other IOKit call passes through. Fake handles sit far above real port names.
enum { kFakeIter = 0xFFFF0001, kFakeGPU = 0xFFFF0002, kFakeAccel = 0xFFFF0003, kFakeChildIter = 0xFFFF0004 };
static BOOL isFake(io_object_t o) { return o >= kFakeIter && o <= kFakeChildIter; }
static int gIterPos[2];
static kern_return_t (*orig_IOServiceGetMatchingServices)(mach_port_t, CFDictionaryRef, io_iterator_t *);
static io_object_t (*orig_IOIteratorNext)(io_iterator_t);
static kern_return_t (*orig_IORegistryEntryCreateCFProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, IOOptionBits);
static kern_return_t (*orig_IORegistryEntryGetChildIterator)(io_registry_entry_t, const io_name_t, io_iterator_t *);
static CFTypeRef (*orig_IORegistryEntrySearchCFProperty)(io_registry_entry_t, const io_name_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static kern_return_t (*orig_IORegistryEntryGetRegistryEntryID)(io_registry_entry_t, uint64_t *);
static kern_return_t (*orig_IOObjectRelease)(io_object_t), (*orig_IOObjectRetain)(io_object_t);

static NSDictionary *fakeProps(io_object_t o) {
    if (o == kFakeGPU) return @{@"device_type": [NSData dataWithBytes:"sgx" length:4], @"name": [NSData dataWithBytes:"gpu" length:4]};
    uint32_t apple = 0x106b;
    return @{@"model": ShackMetalDevice().name ?: @"Apple GPU", @"vendor-id": [NSData dataWithBytes:&apple length:4], @"IOMatchCategory": @"IOAccelerator",
             @"MetalPluginName": @"AGXMetal", @"CFBundleIdentifier": @"com.apple.AGXMetal", @"GLBundleName": @"AppleMetalOpenGLRenderer"};
}
static kern_return_t shack_IOServiceGetMatchingServices(mach_port_t port, CFDictionaryRef match, io_iterator_t *it) {
    if (match && [((__bridge NSDictionary *)match)[@kIOProviderClassKey] isEqual:@"AppleARMIODevice"]) {
        CFRelease(match); gIterPos[0] = 0; *it = kFakeIter; return KERN_SUCCESS;   // the call consumes one reference
    }
    return orig_IOServiceGetMatchingServices(port, match, it);
}
static io_object_t shack_IOIteratorNext(io_iterator_t it) {
    if (it == kFakeIter) return gIterPos[0]++ ? 0 : kFakeGPU;
    if (it == kFakeChildIter) return gIterPos[1]++ ? 0 : kFakeAccel;
    return orig_IOIteratorNext(it);
}
static kern_return_t shack_IORegistryEntryCreateCFProperties(io_registry_entry_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, IOOptionBits o) {
    if (!isFake(e)) return orig_IORegistryEntryCreateCFProperties(e, p, a, o);
    *p = (CFMutableDictionaryRef)CFBridgingRetain([fakeProps(e) mutableCopy]); return KERN_SUCCESS;
}
static kern_return_t shack_IORegistryEntryGetChildIterator(io_registry_entry_t e, const io_name_t plane, io_iterator_t *it) {
    if (!isFake(e)) return orig_IORegistryEntryGetChildIterator(e, plane, it);
    gIterPos[1] = e == kFakeGPU ? 0 : 1; *it = kFakeChildIter; return KERN_SUCCESS;
}
static CFTypeRef shack_IORegistryEntrySearchCFProperty(io_registry_entry_t e, const io_name_t plane, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    if (!isFake(e)) return orig_IORegistryEntrySearchCFProperty(e, plane, key, a, o);
    id v = fakeProps(e)[(__bridge NSString *)key] ?: (e == kFakeGPU && (o & kIORegistryIterateRecursively) ? fakeProps(kFakeAccel)[(__bridge NSString *)key] : nil);
    return v ? CFBridgingRetain(v) : NULL;
}
static kern_return_t shack_IORegistryEntryGetRegistryEntryID(io_registry_entry_t e, uint64_t *id_) {
    if (!isFake(e)) return orig_IORegistryEntryGetRegistryEntryID(e, id_);
    *id_ = ShackMetalDevice().registryID; return KERN_SUCCESS;   // UE matches this against MTLDevice.registryID
}
// The Mac's hardware identity, asked of the registry root ("IOService:/"): Unity's device unique identifier hashes
// IOPlatformUUID and turns a NULL into a garbage string (Akane crashed in XXH32). iOS keeps these from apps; the
// vendor identifier is the stable per-install stand-in.
static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static CFTypeRef shack_IORegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
    NSString *k = (__bridge NSString *)key;
    if ([k isEqualToString:@"IOPlatformUUID"]) {
        NSString *uuid = UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"00000000-0000-4000-8000-000000000000";
        return CFBridgingRetain(uuid);
    }
    if ([k isEqualToString:@"IOPlatformSerialNumber"]) return CFBridgingRetain(@"MACSHACK0001");
    if (isFake(e)) { id v = fakeProps(e)[k]; return v ? CFBridgingRetain(v) : NULL; }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(e, key, a, o) : NULL;
}
// An IOKit plug-in is a table of arm64 function pointers an x86 guest cannot call. Refused, a caller falls back or skips
// the device: Feral's IndirectX (BioShock) skips each HID pad here and uses the IOHIDManager one (ShackHID.m).
static kern_return_t shack_guest_IOCreatePlugInInterfaceForService(io_service_t s, CFUUIDRef type, CFUUIDRef iface, void ***out, SInt32 *score) {
    return kIOReturnUnsupported;
}
static kern_return_t shack_IOObjectRelease(io_object_t o) { return isFake(o) ? KERN_SUCCESS : orig_IOObjectRelease(o); }
static kern_return_t shack_IOObjectRetain(io_object_t o) { return isFake(o) ? KERN_SUCCESS : orig_IOObjectRetain(o); }

// Case-insensitive fallback for the guest's files. Mac games (UE4 lowercases shader library names) expect a
// case-insensitive volume; iOS APFS is case-sensitive. On ENOENT for a guest path (relative: cwd is inside the
// guest; or under the app container, spelled in any case) each missing component is matched case-insensitively
// and the call retried. Crimson Desert lowercases whole save paths ("/var/mobile/containers/.../library/application
// support/pearl abyss/..."). A missing last component stays as given, so creates (O_CREAT, mkdir, rename) work too.
// ponytail: no cache; each miss rescans the directories on its path. Add one if the probes show up in profiles.
// ponytail: only ENOENT retries; creating "save" beside an existing "Save" in a correctly cased directory still makes
// a second entry (macOS would reuse it). Resolve before creates if a game needs that.
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
static char gGuestRoot[PATH_MAX], gHome[PATH_MAX], gHomeReal[PATH_MAX];
static int (*o_open)(const char *, int, ...), (*o_stat)(const char *, struct stat *), (*o_lstat)(const char *, struct stat *), (*o_access)(const char *, int);
static DIR *(*o_opendir)(const char *);
// A path inside this app's data container from an earlier MacShack install: iOS gives the container a new UUID at every
// install, and games keep absolute paths (Tunic's save list: DirectoryNotFound at Continue, then a black screen with its
// main thread spinning, 2026-10-04). The same place in today's container.
static BOOL MovedContainer(const char *path, char *out, size_t n) {
    static const char *const prefixes[] = {"/private/var/mobile/Containers/Data/Application/", "/var/mobile/Containers/Data/Application/"};
    for (int i = 0; i < 2; i++) {
        size_t len = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], len)) continue;
        const char *rest = strchr(path + len, '/');   // after the UUID
        if (!rest || rest - (path + len) != 36) return NO;
        size_t home = strlen(gHome), real = strlen(gHomeReal);
        if (!strncmp(path, gHome, home) || !strncmp(path, gHomeReal, real)) return NO;   // already today's
        return snprintf(out, n, "%s%s", gHome, rest) < (int)n;
    }
    return NO;
}
BOOL ShackResolveCase(const char *path, char *out, size_t n) {
    if (!*gGuestRoot || !o_lstat || !o_opendir || !path || !*path) return NO;
    char moved[PATH_MAX];
    if (MovedContainer(path, moved, sizeof moved)) {   // then its case, as for any other path
        if (!ShackResolveCase(moved, out, n)) strlcpy(out, moved, n);
        return YES;
    }
    const char *root = ""; size_t skip = 0;
    if (path[0] == '/') {
        const char *roots[] = {gGuestRoot, gHome, gHomeReal, gSecond.root};
        for (int i = 0; i < 4 && !skip; i++) {
            size_t len = strlen(roots[i]);
            if (len && !strncasecmp(path, roots[i], len) && (path[len] == '/' || !path[len])) { root = roots[i]; skip = len; }
        }
        if (!skip) return NO;
    }
    char buf[PATH_MAX]; if (strlcpy(buf, path + skip, sizeof buf) >= sizeof buf) return NO;
    strlcpy(out, root, n);
    BOOL changed = skip && strncmp(path, root, skip); struct stat st;
    for (char *save, *c = strtok_r(buf, "/", &save); c; c = strtok_r(NULL, "/", &save)) {
        size_t base = strlen(out);
        if (base && out[base - 1] != '/') strlcat(out, "/", n);
        size_t dirLen = strlen(out);
        strlcat(out, c, n);
        if (!strcmp(c, ".") || !strcmp(c, "..") || o_lstat(out, &st) == 0) continue;
        out[dirLen] = 0;
        DIR *d = o_opendir(dirLen ? out : "."); if (!d) return NO;
        struct dirent *e; BOOL found = NO;
        while ((e = readdir(d))) if (!strcasecmp(e->d_name, c)) { strlcat(out, e->d_name, n); found = changed = YES; break; }
        closedir(d);
        if (!found) { if (save && save[strspn(save, "/")]) return NO; strlcat(out, c, n); }   // a new last component
    }
    return changed;
}
// SHACK_FILELOG=1 (diagnostic): each missing path (first 500, or the first <n> with SHACK_FILELOG=<n>), with the case
// fix when one was found.
static void FileMiss(const char *call, const char *path, const char *fixed) {
    static int max = -1, n; if (max < 0) { const char *v = getenv("SHACK_FILELOG"); max = !v ? 0 : atoi(v) > 1 ? atoi(v) : 500; }
    if (n++ < max) fprintf(stderr, "[MacShack] %s miss: %s%s%s\n", call, path, fixed ? " -> " : "", fixed ?: "");
}
#define CI_RETRY(name, call, fail) ({ __typeof__(call) _r = (call); if (_r == (fail) && errno == ENOENT) { char _p[PATH_MAX]; int _e = errno; \
    if (ShackResolveCase(p, _p, sizeof _p)) { FileMiss(name, p, _p); p = _p; _r = (call); } else { FileMiss(name, p, NULL); errno = _e; } } _r; })
static int ci_open(const char *p, int f, ...) { va_list ap; va_start(ap, f); int m = (f & O_CREAT) ? va_arg(ap, int) : 0; va_end(ap); return CI_RETRY("open", o_open(p, f, m), -1); }
static int ci_stat(const char *p, struct stat *b) { return CI_RETRY("stat", o_stat(p, b), -1); }
static int ci_lstat(const char *p, struct stat *b) { return CI_RETRY("lstat", o_lstat(p, b), -1); }
static int ci_access(const char *p, int m) { return CI_RETRY("access", o_access(p, m), -1); }
static DIR *ci_opendir(const char *p) { return CI_RETRY("opendir", o_opendir(p), (DIR *)NULL); }
// fopen opens inside libc, past the rebinding of open (Crimson Desert looks for Resources/Packages; the folder is "packages").
static FILE *(*o_fopen)(const char *, const char *);
static FILE *ci_fopen(const char *p, const char *m) { return CI_RETRY("fopen", o_fopen(p, m), (FILE *)NULL); }
// Saving: a new slot directory, a temp file renamed over the save, the old one removed (remove() unlinks inside libc).
static int (*o_mkdir)(const char *, mode_t), (*o_unlink)(const char *), (*o_rmdir)(const char *), (*o_remove)(const char *);
static int ci_mkdir(const char *p, mode_t m) { return CI_RETRY("mkdir", o_mkdir(p, m), -1); }
static int ci_unlink(const char *p) { return CI_RETRY("unlink", o_unlink(p), -1); }
static int ci_rmdir(const char *p) { return CI_RETRY("rmdir", o_rmdir(p), -1); }
static int ci_remove(const char *p) { return CI_RETRY("remove", o_remove(p), -1); }
static int (*o_rename)(const char *, const char *);
static int ci_rename(const char *a, const char *b) {
    int r = o_rename(a, b), e = errno; if (r == 0 || e != ENOENT) return r;
    char ra[PATH_MAX], rb[PATH_MAX];
    BOOL fa = ShackResolveCase(a, ra, sizeof ra), fb = ShackResolveCase(b, rb, sizeof rb);
    FileMiss("rename", a, fa ? ra : NULL); FileMiss("rename", b, fb ? rb : NULL);
    if (!fa && !fb) { errno = e; return r; }
    return o_rename(fa ? ra : a, fb ? rb : b);
}

// Unity dlopens Mono, Burst and native plugins from its own bundle, i.e. Documents; load the prepared signed copy.
static char gGuestCode[PATH_MAX];
static CFURLRef (*orig_CFBundleCopyExecutableURL)(CFBundleRef);
static CFURLRef shack_CFBundleCopyExecutableURL(CFBundleRef bundle) {
    CFURLRef native = orig_CFBundleCopyExecutableURL ? orig_CFBundleCopyExecutableURL(bundle) : NULL;
    if (native || !bundle) return native;
    NSURL *url = CFBridgingRelease(CFBundleCopyBundleURL(bundle));
    char root[PATH_MAX], executable[PATH_MAX];
    if (!url.isFileURL || !realpath(url.fileSystemRepresentation, root)) return NULL;
    // The first guest's bundles, or the second guest's (a game the Steam client started: Okko's fmodstudio.bundle).
    const char *guestRoot = *gSecond.root && underRoot(root, gSecond.root) ? gSecond.root : gGuestRoot;
    size_t guestLength = strlen(guestRoot);
    if (strncmp(root, guestRoot, guestLength) || (root[guestLength] && root[guestLength] != '/')) return NULL;
    NSString *path = @(root);
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    // No Info.plist, or no CFBundleExecutable in it: macOS names the executable after the bundle (Unity's plugin
    // bundles ship without one: Akane's fmodstudio.bundle).
    NSString *name = info[@"CFBundleExecutable"] ?: path.lastPathComponent.stringByDeletingPathExtension;
    if (![name isKindOfClass:NSString.class] || !name.length || ![name.lastPathComponent isEqual:name] ||
        [name isEqual:@"."] || [name isEqual:@".."] || [name rangeOfString:@"\0"].location != NSNotFound) return NULL;
    NSString *candidate = [path stringByAppendingFormat:@"/Contents/MacOS/%@", name];
    struct stat st;
    size_t rootLength = strlen(root);
    if (!realpath(candidate.fileSystemRepresentation, executable) ||
        strncmp(executable, root, rootLength) || executable[rootLength] != '/' ||
        stat(executable, &st) || !S_ISREG(st.st_mode)) return NULL;
    // Keep the data path here; shack_dlopen redirects it to the signed private copy.
    fprintf(stderr, "[MacShack] desktop bundle executable: %s\n", executable + guestLength + 1);
    return CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)executable, strlen(executable), false);
}

// GLFW looks desktop frameworks up by bundle identifier and resolves functions by name. HIToolbox (TIS keyboard
// layout) is served by the loaded Carbon shim; with SHACK_OPENGL=1, OpenGL by libShackAppKit's GL-on-ES layer
// (shims/AppKit/ShackGL.m). Stand-in bundles are real CFBundles of iOS frameworks, used only as identities here.
static CFBundleRef gGLBundle, gTISBundle;
static void *(*gGLGetProc)(const char *);
static CFBundleRef (*orig_CFBundleGetBundleWithIdentifier)(CFStringRef);
static CFBundleRef shack_CFBundleGetBundleWithIdentifier(CFStringRef ident) {
    if (gGLBundle && ident && CFEqual(ident, CFSTR("com.apple.opengl"))) return gGLBundle;
    if (ident && CFEqual(ident, CFSTR("com.apple.HIToolbox"))) return gTISBundle;
    return orig_CFBundleGetBundleWithIdentifier(ident);
}
static void *shimSymbol(CFBundleRef bundle, CFStringRef name) {
    char n[256];
    if (!CFStringGetCString(name, n, sizeof n, kCFStringEncodingASCII)) return NULL;
    return bundle == gGLBundle ? gGLGetProc(n) : dlsym(RTLD_DEFAULT, n);
}
static void *(*orig_CFBundleGetFunctionPointerForName)(CFBundleRef, CFStringRef);
static void *shack_CFBundleGetFunctionPointerForName(CFBundleRef bundle, CFStringRef name) {
    if (bundle && (bundle == gGLBundle || bundle == gTISBundle)) return shimSymbol(bundle, name);
    return orig_CFBundleGetFunctionPointerForName(bundle, name);
}
static void *(*orig_CFBundleGetDataPointerForName)(CFBundleRef, CFStringRef);
static void *shack_CFBundleGetDataPointerForName(CFBundleRef bundle, CFStringRef name) {
    if (bundle && bundle == gTISBundle) return shimSymbol(bundle, name);
    return orig_CFBundleGetDataPointerForName(bundle, name);
}

// glad (Godot 3) dlopens the OpenGL framework by path and dlsyms from that handle: with SHACK_OPENGL=1 the handle is
// a stand-in whose symbols come from the GL layer, like the bundle lookups above.
static char gGLHandleTag;
#define GL_HANDLE ((void *)&gGLHandleTag)
static void *(*o_dlsym)(void *, const char *);
static void *shack_dlsym(void *h, const char *name) { return h == GL_HANDLE ? gGLGetProc(name) : o_dlsym(h, name); }
static int (*o_dlclose)(void *);
static int shack_dlclose(void *h) { return h == GL_HANDLE ? 0 : o_dlclose(h); }

// The game sees its images where its data is, as it sees its bundle and executable: Library/Guests/<Name>/<gen>/X is
// reported as Documents/Games/<Name>.app/X (the untouched originals) when that file exists, by _dyld_get_image_name and
// dladdr. Crimson Desert finds its Steam library in the image list and SHA-256s the file: the prepared copy is re-signed, the
// data copy is publisher-signed. Steam's tier0 finds the Steam folder (steamui, steam.cfg) beside its own image.
static NSDictionary<NSString *, NSString *> *gImageAliases;
void ShackHooksSetImageAliases(NSDictionary<NSString *, NSString *> *aliases) { gImageAliases = aliases.copy; }
static const char *dataImageName(const char *name) {
    if (!name || !*gGuestCode) return name;
    BOOL second = *gSecond.code && underRoot(name, gSecond.code);
    const char *code = second ? gSecond.code : gGuestCode;
    size_t n = strlen(code); const char *rest = NULL;
    if (!strncmp(name, code, n)) rest = name + n;
    else if (!strncmp(code, "/private/", 9) && !strncmp(name, code + 8, n - 8)) rest = name + n - 8;   // dyld keeps /var
    if (!rest || *rest != '/') return name;
    static NSMutableDictionary<NSValue *, NSValue *> *mapped; static dispatch_once_t once; dispatch_once(&once, ^{ mapped = [NSMutableDictionary dictionary]; });
    NSValue *key = [NSValue valueWithPointer:name];
    @synchronized(mapped) {
        if (!mapped[key]) {
            NSString *alias = second ? nil : gImageAliases[@(rest + 1)];
            char data[PATH_MAX]; struct stat st;
            NSBundle *bundle = second ? gSecond.bundle : gGuestBundle;
            BOOL ok = (size_t)snprintf(data, sizeof data, "%s/%s", bundle.bundlePath.fileSystemRepresentation, alias ? alias.fileSystemRepresentation : rest + 1) < sizeof data && o_stat(data, &st) == 0;
            mapped[key] = [NSValue valueWithPointer:ok ? strdup(data) : name];   // image names live as long as the process
        }
        return mapped[key].pointerValue;
    }
}
static const char *(*o_dyld_get_image_name)(uint32_t);
static const char *shack_dyld_get_image_name(uint32_t i) {
    const char *name = o_dyld_get_image_name(i);
    return *gGuestCode && isGuestCaller(__builtin_return_address(0)) ? dataImageName(name) : name;
}
static int shack_dladdr(const void *a, Dl_info *info) {
    int r = o_dladdr(a, info);
    if (r && *gGuestCode && isGuestCaller(__builtin_return_address(0))) info->dli_fname = dataImageName(info->dli_fname);
    return r;
}

static void *(*o_dlopen)(const char *, int);
static void *shack_dlopen(const char *p, int mode) {
    size_t n0 = p ? strlen(p) : 0;
    if (gGLBundle && n0 >= 23 && !strcmp(p + n0 - 23, "OpenGL.framework/OpenGL")) return GL_HANDLE;
    char real[PATH_MAX], alt[PATH_MAX], cased[PATH_MAX]; struct stat st; size_t n = strlen(gGuestRoot);
    // Stray asks for libAPEXFramework.dylib and ships libApexFramework.dylib: same case fallback as file opens.
    if (p && o_stat(p, &st) != 0 && ShackResolveCase(p, cased, sizeof cased)) p = cased;
    const char *root = gGuestRoot, *code = gGuestCode;
    if (p && realpath(p, real) && *gSecond.root && underRoot(real, gSecond.root)) { root = gSecond.root; code = gSecond.code; n = strlen(root); }
    if (p && realpath(p, real) && !strncmp(real, root, n) && real[n] == '/'
        && (size_t)snprintf(alt, sizeof alt, "%s%s", code, real + n) < sizeof alt && o_stat(alt, &st) == 0) {
        fprintf(stderr, "[MacShack] dlopen %s -> prepared code\n", real + n + 1);
        p = alt;
    }
    return o_dlopen(p, mode);
}

// iOS refuses mmap(MAP_JIT) with EPERM; Mono's code allocator does not check the failure and
// memset()s the returned pointer, crashing a Unity/Mono guest before any generated code runs.
// Give MAP_JIT requests ordinary read-write memory so the allocation and Mono's writes succeed.
// The EXEC bit is dropped: this grants NO execute permission and touches no debugger — executing
// the memory still faults without the separate JIT enablement layer.
static void *(*orig_mmap)(void *, size_t, int, int, int, off_t);
static void *shack_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    void *pool = (prot & PROT_EXEC) && fd == -1 ? ShackTrapJITAlloc(len) : NULL;   // stock Mono: code comes from the JIT pool
    if (pool) return pool;
    if (flags & MAP_JIT) { flags &= ~MAP_JIT; prot &= ~PROT_EXEC; return orig_mmap(addr, len, prot, flags, fd, off); }
    return ShackSwapMmap(addr, len, prot, flags, fd, off, __builtin_return_address(0), orig_mmap);   // ShackSwap.c
}
static int (*orig_munmap)(void *, size_t);
static int shack_munmap(void *addr, size_t len) { return ShackTrapJITOwns(addr) ? 0 : ShackSwapMunmap(addr, len, __builtin_return_address(0), orig_munmap); }

// kCFURLHFSPathStyle: iOS's CoreFoundation answers NULL, macOS a colon path ("Macintosh HD:Users:me:Game:"). Feral's launcher
// asks for one of its data folder and then takes the parent of the result, so NULL crashed it in CFURLCreateCopy....
static CFStringRef shack_CFURLCopyFileSystemPath(CFURLRef url, CFURLPathStyle style) {
    if (style != kCFURLHFSPathStyle) return CFURLCopyFileSystemPath(url, style);
    CFStringRef posix = url ? CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) : NULL;
    if (!posix) return NULL;
    NSMutableString *hfs = [NSMutableString stringWithString:@"Macintosh HD"];
    for (NSString *part in [(__bridge NSString *)posix componentsSeparatedByString:@"/"]) if (part.length) [hfs appendFormat:@":%@", part];
    if (CFURLHasDirectoryPath(url)) [hfs appendString:@":"];
    CFRelease(posix);
    return (CFStringRef)CFBridgingRetain(hfs);
}

// The other direction: an HFS path names the volume first ("Macintosh HD:Users:me:Game:"), and iOS's CoreFoundation would turn its
// colons into slashes and keep the volume name (/Macintosh HD/Users/...), a path nothing has. A leading colon means relative.
// An empty HFS path names nothing, not the root (FMOD's CD-audio probe builds one for a sound loaded from memory, asks CFURLGetFSRef
// whether "<name>:.TOC.plist" exists, took our "/" for an audio CD and read a table that was never there).
static NSString *PosixFromHFS(CFStringRef hfs) {
    if (![(__bridge NSString *)hfs length]) return @"";
    NSArray *parts = [(__bridge NSString *)hfs componentsSeparatedByString:@":"];
    BOOL relative = [(__bridge NSString *)hfs hasPrefix:@":"];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSUInteger i = relative ? 0 : 1; i < parts.count; i++) if ([parts[i] length]) [kept addObject:parts[i]];   // parts[0] is the volume
    NSString *joined = [kept componentsJoinedByString:@"/"];
    return relative ? joined : [@"/" stringByAppendingString:joined];
}
static CFURLRef shack_CFURLCreateWithFileSystemPath(CFAllocatorRef alloc, CFStringRef path, CFURLPathStyle style, Boolean dir) {
    if (style != kCFURLHFSPathStyle || !path) return CFURLCreateWithFileSystemPath(alloc, path, style, dir);
    return CFURLCreateWithFileSystemPath(alloc, (__bridge CFStringRef)PosixFromHFS(path), kCFURLPOSIXPathStyle, dir);
}
static CFURLRef shack_CFURLCreateWithFileSystemPathRelativeToBase(CFAllocatorRef alloc, CFStringRef path, CFURLPathStyle style, Boolean dir, CFURLRef base) {
    if (style != kCFURLHFSPathStyle || !path) return CFURLCreateWithFileSystemPathRelativeToBase(alloc, path, style, dir, base);
    return CFURLCreateWithFileSystemPathRelativeToBase(alloc, (__bridge CFStringRef)PosixFromHFS(path), kCFURLPOSIXPathStyle, dir, base);
}

// FSRefs are the Carbon shim's (ShackLegacy.m): the two CoreFoundation calls that convert between a ref and a URL live here.
static CFURLRef shack_CFURLCreateFromFSRef(CFAllocatorRef alloc, const void *ref) {
    NSString *(*path)(const void *) = dlsym(RTLD_DEFAULT, "ShackFSRefPath");
    NSString *p = path ? path(ref) : nil;
    if (!p) return NULL;
    BOOL dir = NO; [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir];
    return CFURLCreateWithFileSystemPath(alloc, (__bridge CFStringRef)p, kCFURLPOSIXPathStyle, dir);
}
static Boolean shack_CFURLGetFSRef(CFURLRef url, void *ref) {
    void (*make)(NSString *, void *) = dlsym(RTLD_DEFAULT, "ShackFSRefMake");
    NSString *p = url ? CFBridgingRelease(CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle)) : nil;
    if (!p || !make || ![NSFileManager.defaultManager fileExistsAtPath:p]) return false;
    make(p, ref);
    return true;
}

// OpenAL's GetProcAddress answers host arm64 addresses, and the guest jumps to them as x86 (Feral's alcASASetListener call faulted inside
// OpenAL). Answer a thunk that crosses the bridge for the functions Feral looks up, and NULL for any other name.
uint64_t ocerz_bridge_native_thunk(const void *fn, const char *name, const char *notation);
static void *AudioProcThunk(void *fn, const char *name) {
    static const struct { const char *name, *notation; } sigs[] = {
        {"alcASASetListener", "i(upu)"}, {"alcASASetSource", "i(uupu)"}, {"alBufferDataStatic", "v(iipii)"},
        {"alcMacOSXMixerMaxiumumBusses", "v(i)"},
        {"alSourceAddNotification", "i(uuc{v(uup)}p)"}, {"alSourceRemoveNotification", "i(uuc{v(uup)}p)"}};
    if (!fn || !name) return NULL;
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++)
        if (!strcmp(name, sigs[i].name)) return (void *)ocerz_bridge_native_thunk(fn, name, sigs[i].notation);
    return NULL;
}
static void *shack_alcGetProcAddress(void *dev, const char *name) {
    void *(*f)(void *, const char *) = dlsym(RTLD_DEFAULT, "alcGetProcAddress");
    return f ? AudioProcThunk(f(dev, name), name) : NULL;
}
static void *shack_alGetProcAddress(const char *name) {
    void *(*f)(const char *) = dlsym(RTLD_DEFAULT, "alGetProcAddress");
    return f ? AudioProcThunk(f(name), name) : NULL;
}

static void *(*gGuestSymbolAnswer)(const char *name);
void ShackHooksSetGuestSymbolAnswer(void *(*answer)(const char *name)) { gGuestSymbolAnswer = answer; }

// An Intel game's calls reach the host through AArchX's dlsym, which fishhook never changes: it asks here first.
// Only identity, preferences, case-insensitive paths and the IOKit registry; exit, signals, dl* and mmap stay
// AArchX's own (it runs the guest's memory, signals and loader itself).
void *ShackHookForGuestSymbol(const char *name) {
    static const struct { const char *name; void *fn; } hooks[] = {
        {"CFBundleGetMainBundle", shack_CFBundleGetMainBundle}, {"CFBundleCopyExecutableURL", shack_CFBundleCopyExecutableURL},
        {"CFBundleGetBundleWithIdentifier", shack_CFBundleGetBundleWithIdentifier},
        {"CFPreferencesCopyAppValue", shack_CFPreferencesCopyAppValue},
        {"CFPreferencesGetAppBooleanValue", shack_CFPreferencesGetAppBooleanValue},
        {"CFPreferencesGetAppIntegerValue", shack_CFPreferencesGetAppIntegerValue},
        {"SCDynamicStoreCopyComputerName", shack_SCDynamicStoreCopyComputerName}, {"proc_pidpath", shack_proc_pidpath},
        {"stat", ci_stat}, {"lstat", ci_lstat}, {"access", ci_access}, {"opendir", ci_opendir},
        {"IOServiceGetMatchingServices", shack_IOServiceGetMatchingServices}, {"IOIteratorNext", shack_IOIteratorNext},
        {"IORegistryEntryCreateCFProperties", shack_IORegistryEntryCreateCFProperties},
        {"IORegistryEntryGetChildIterator", shack_IORegistryEntryGetChildIterator},
        {"IORegistryEntrySearchCFProperty", shack_IORegistryEntrySearchCFProperty},
        {"IORegistryEntryCreateCFProperty", shack_IORegistryEntryCreateCFProperty},
        {"IORegistryEntryGetRegistryEntryID", shack_IORegistryEntryGetRegistryEntryID},
        {"IOObjectRelease", shack_IOObjectRelease}, {"IOObjectRetain", shack_IOObjectRetain},
        {"IOCreatePlugInInterfaceForService", shack_guest_IOCreatePlugInInterfaceForService},
        {"CFURLCopyFileSystemPath", shack_CFURLCopyFileSystemPath}, {"CFURLCreateWithFileSystemPath", shack_CFURLCreateWithFileSystemPath},
        {"CFURLCreateWithFileSystemPathRelativeToBase", shack_CFURLCreateWithFileSystemPathRelativeToBase},
        {"CFURLCreateFromFSRef", shack_CFURLCreateFromFSRef}, {"CFURLGetFSRef", shack_CFURLGetFSRef},
        {"alcGetProcAddress", shack_alcGetProcAddress}, {"alGetProcAddress", shack_alGetProcAddress},
        {"CFXMLTreeCreateFromData", CFXMLTreeCreateFromData}, {"CFXMLTreeGetNode", CFXMLTreeGetNode},   // iOS CoreFoundation has no CFXMLParser
        {"CFXMLNodeGetString", CFXMLNodeGetString}, {"CFXMLNodeGetTypeCode", CFXMLNodeGetTypeCode},
        {"CFXMLNodeGetInfoPtr", CFXMLNodeGetInfoPtr}, {"CFXMLNodeGetVersion", CFXMLNodeGetVersion},
    };
    if (!gGuestCFBundle) return NULL;   // before ShackHooksInstall the originals are not set yet
    // Desktop GL (SHACK_OPENGL=1): the same translations and ES functions an arm64 game gets through dlsym
    if (gGLGetProc && name[0] == 'g' && name[1] == 'l') return gGLGetProc(name);
    for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++)
        if (!strcmp(name, hooks[i].name)) return hooks[i].fn;
    return gGuestSymbolAnswer ? gGuestSymbolAnswer(name) : NULL;
}

void ShackHooksAddGuest(NSString *bundlePath, NSString *execPath, NSString *codePath, BOOL translated, void (^ended)(int code)) {
    noteGuestStarted();
    gSecond.translated = translated;
    gSecond.bundle = [NSBundle bundleWithPath:bundlePath];
    gSecond.cfBundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:bundlePath]);
    strlcpy(gSecond.exec, execPath.fileSystemRepresentation, sizeof gSecond.exec);
    realpath(bundlePath.fileSystemRepresentation, gSecond.root);
    gSecond.ended = [ended copy];
    NSString *prefsID = gSecond.bundle.bundleIdentifier;
    if (prefsID.length && (gSecond.defaults = [[NSUserDefaults alloc] initWithSuiteName:prefsID])) gSecond.prefsID = CFBridgingRetain(prefsID);
    int crashes[] = {SIGILL, SIGTRAP};   // its crashes end it alone (secondGuestCrashed)
    for (int i = 0; i < 2; i++) {
        int sig = crashes[i];
        struct sigaction cur = {0}, fault = {0};
        orig_sigaction(sig, NULL, &cur);
        if (cur.sa_sigaction == shack_fault) continue;
        if (cur.sa_handler != SIG_DFL && cur.sa_handler != SIG_IGN) gGuestAct[sig] = cur;
        fault.sa_sigaction = shack_fault; fault.sa_flags = SA_SIGINFO | SA_ONSTACK;
        orig_sigaction(sig, &fault, NULL);
    }
    realpath(codePath.fileSystemRepresentation, gSecond.code);   // last: a code root makes the second guest live
    NSLog(@"[MacShack] second guest %@ (code %s, preferences %@)", bundlePath.lastPathComponent, gSecond.code, gSecond.prefsID ? (__bridge NSString *)gSecond.prefsID : @"MacShack's");
}
void ShackHooksAdoptGuestThread(void) { tSecondThread = YES; }
BOOL ShackHooksIsSecondCaller(const void *pc) { return isSecondCaller(pc); }
void ShackHooksEnableGL(void) {
    if (!gGLBundle && (gGLGetProc = dlsym(RTLD_DEFAULT, "ShackGLGetProcAddress")))
        gGLBundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/Frameworks/OpenGLES.framework"]);
}

void ShackHooksInstall(NSString *bundlePath, NSString *execPath, NSString *codePath) {
    // Once only: a second swap would undo the first, and fishhook would save our own
    // shack_proc_pidpath as the original (infinite recursion for foreign pids).
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ShackMetalFixups();
        gGuestBundle = [NSBundle bundleWithPath:bundlePath];
        gGuestCFBundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:bundlePath]);
        strlcpy(gGuestExec, execPath.fileSystemRepresentation, sizeof gGuestExec);
        realpath(bundlePath.fileSystemRepresentation, gGuestRoot);
        strlcpy(gHome, NSHomeDirectory().fileSystemRepresentation, sizeof gHome);   // /var/mobile/...; realpath: /private/var/...
        realpath(gHome, gHomeReal);
        realpath(codePath.fileSystemRepresentation, gGuestCode);
        const char *gl = getenv("SHACK_OPENGL");
        if (gl && gl[0] == '1' && (gGLGetProc = dlsym(RTLD_DEFAULT, "ShackGLGetProcAddress")))
            gGLBundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/Frameworks/OpenGLES.framework"]);
        gTISBundle = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:@"/System/Library/Frameworks/CoreServices.framework"]);
        Method a = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        Method b = class_getClassMethod(NSBundle.class, @selector(shack_mainBundle));
        method_exchangeImplementations(a, b);
        method_exchangeImplementations(class_getInstanceMethod(NSURL.class, @selector(getResourceValue:forKey:error:)),
                                       class_getInstanceMethod(NSURL.class, @selector(shack_getResourceValue:forKey:error:)));
        method_exchangeImplementations(class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:)),
                                       class_getInstanceMethod(NSFileManager.class, @selector(shack_containerURLForSecurityApplicationGroupIdentifier:)));
        gAfterGameFrame = [NSMutableArray array];
        noteGuestStarted();
        [NSNotificationCenter.defaultCenter addObserverForName:@"ShackLayerFirstFrame" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            gNewLayerDrew = CACurrentMediaTime();
            for (dispatch_block_t go in gAfterGameFrame) go();
            [gAfterGameFrame removeAllObjects];
        }];
        method_exchangeImplementations(class_getInstanceMethod(NSNotificationCenter.class, @selector(addObserver:selector:name:object:)),
                                       class_getInstanceMethod(NSNotificationCenter.class, @selector(shack_addObserver:selector:name:object:)));
        method_exchangeImplementations(class_getInstanceMethod(NSNotificationCenter.class, @selector(addObserverForName:object:queue:usingBlock:)),
                                       class_getInstanceMethod(NSNotificationCenter.class, @selector(shack_addObserverForName:object:queue:usingBlock:)));
        gHostArgv = *_NSGetArgv();
        method_exchangeImplementations(class_getInstanceMethod(NSProcessInfo.class, @selector(arguments)),
                                       class_getInstanceMethod(NSProcessInfo.class, @selector(shack_arguments)));
        for (NSString *sel in @[@"executablePath", @"executableURL"])
            method_exchangeImplementations(class_getInstanceMethod(NSBundle.class, NSSelectorFromString(sel)),
                                           class_getInstanceMethod(NSBundle.class, NSSelectorFromString([@"shack_" stringByAppendingString:sel])));
        NSString *prefsID = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleIdentifier"];
        if (![prefsID isKindOfClass:NSString.class] || !prefsID.length) prefsID = [@"macshack.guest." stringByAppendingString:bundlePath.lastPathComponent.stringByDeletingPathExtension];
        if ((gGuestDefaults = [[NSUserDefaults alloc] initWithSuiteName:prefsID])) {   // nil if it names MacShack itself
            gGuestPrefsID = CFBridgingRetain(prefsID);
            method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
                                           class_getClassMethod(NSUserDefaults.class, @selector(shack_standardUserDefaults)));
            NSLog(@"[MacShack] guest preferences: %@", prefsID);
        }
        struct rebinding r[] = {
            {"CFPreferencesCopyAppValue", shack_CFPreferencesCopyAppValue, (void **)&orig_CFPreferencesCopyAppValue},
            {"CFPreferencesGetAppBooleanValue", shack_CFPreferencesGetAppBooleanValue, (void **)&orig_CFPreferencesGetAppBooleanValue},
            {"CFPreferencesGetAppIntegerValue", shack_CFPreferencesGetAppIntegerValue, (void **)&orig_CFPreferencesGetAppIntegerValue},
            {"_NSGetExecutablePath", shack_NSGetExecutablePath, (void **)&orig_NSGetExecutablePath},
            {"proc_pidpath", shack_proc_pidpath, (void **)&orig_proc_pidpath},
            {"CFBundleGetMainBundle", shack_CFBundleGetMainBundle, NULL},
            {"CFBundleCopyExecutableURL", shack_CFBundleCopyExecutableURL, (void **)&orig_CFBundleCopyExecutableURL},
            {"CFBundleGetBundleWithIdentifier", shack_CFBundleGetBundleWithIdentifier, (void **)&orig_CFBundleGetBundleWithIdentifier},
            {"CFBundleGetFunctionPointerForName", shack_CFBundleGetFunctionPointerForName, (void **)&orig_CFBundleGetFunctionPointerForName},
            {"CFBundleGetDataPointerForName", shack_CFBundleGetDataPointerForName, (void **)&orig_CFBundleGetDataPointerForName},
            {"SCDynamicStoreCopyComputerName", shack_SCDynamicStoreCopyComputerName, (void **)&orig_SCDynamicStoreCopyComputerName},
            {"exit", shack_exit, (void **)&orig_exit},
            {"_exit", shack__exit, (void **)&orig__exit},
            {"_Exit", shack__Exit, (void **)&orig__Exit},
            {"abort", shack_abort, (void **)&orig_abort},
            {"sigaction", shack_sigaction, (void **)&orig_sigaction},
            {"signal", shack_signal, NULL},
            {"IOServiceGetMatchingServices", shack_IOServiceGetMatchingServices, (void **)&orig_IOServiceGetMatchingServices},
            {"IOIteratorNext", shack_IOIteratorNext, (void **)&orig_IOIteratorNext},
            {"IORegistryEntryCreateCFProperties", shack_IORegistryEntryCreateCFProperties, (void **)&orig_IORegistryEntryCreateCFProperties},
            {"IORegistryEntryGetChildIterator", shack_IORegistryEntryGetChildIterator, (void **)&orig_IORegistryEntryGetChildIterator},
            {"IORegistryEntrySearchCFProperty", shack_IORegistryEntrySearchCFProperty, (void **)&orig_IORegistryEntrySearchCFProperty},
            {"IORegistryEntryCreateCFProperty", shack_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty},
            {"IORegistryEntryGetRegistryEntryID", shack_IORegistryEntryGetRegistryEntryID, (void **)&orig_IORegistryEntryGetRegistryEntryID},
            {"IOObjectRelease", shack_IOObjectRelease, (void **)&orig_IOObjectRelease},
            {"IOObjectRetain", shack_IOObjectRetain, (void **)&orig_IOObjectRetain},
            {"open", ci_open, (void **)&o_open}, {"stat", ci_stat, (void **)&o_stat}, {"lstat", ci_lstat, (void **)&o_lstat},
            {"access", ci_access, (void **)&o_access}, {"opendir", ci_opendir, (void **)&o_opendir}, {"fopen", ci_fopen, (void **)&o_fopen},
            {"mkdir", ci_mkdir, (void **)&o_mkdir}, {"unlink", ci_unlink, (void **)&o_unlink}, {"rmdir", ci_rmdir, (void **)&o_rmdir},
            {"remove", ci_remove, (void **)&o_remove}, {"rename", ci_rename, (void **)&o_rename},
            {"dlopen", shack_dlopen, (void **)&o_dlopen},
            {"_dyld_get_image_name", shack_dyld_get_image_name, (void **)&o_dyld_get_image_name},
            {"dladdr", shack_dladdr, (void **)&o_dladdr},
            {"dlsym", shack_dlsym, (void **)&o_dlsym},
            {"dlclose", shack_dlclose, (void **)&o_dlclose},
            {"mmap", shack_mmap, (void **)&orig_mmap},
            {"munmap", shack_munmap, (void **)&orig_munmap},
        };
        // Originals come from dlsym, not fishhook: fishhook only fills them in if some already-loaded image imports the
        // symbol, and a hook whose original is still NULL when a later image calls it jumps to 0.
        for (size_t i = 0; i < sizeof r / sizeof *r; i++)
            if (r[i].replaced) { *r[i].replaced = dlsym(RTLD_DEFAULT, r[i].name); r[i].replaced = NULL; }
        rebind_symbols(r, sizeof r / sizeof *r);   // ponytail: rebinds every image incl. the host; fine, the host is done after launch
        struct sigaction fault = {0}; fault.sa_sigaction = shack_fault; fault.sa_flags = SA_SIGINFO | SA_ONSTACK;
        orig_sigaction(SIGSEGV, &fault, NULL); orig_sigaction(SIGBUS, &fault, NULL);
        ShackTrapJITHookMono();

        // One C++ allocator for every guest image: the system's. A game can export its own global operator new/delete
        // (Valheim's UnityPlayer does); iOS then resolves other images' operator new binds to it, while the system libc++
        // (shared cache) keeps malloc/free. A plugin's std::string destroyed or grown inside the system libc++ is then
        // freed with free() and malloc aborts (PlayFab Party in Valheim). On macOS the whole process, system libc++
        // included, follows the game's allocator, so games never see this. Unity's own calls are direct, not via binds.
        static const char *cxxAlloc[] = {
            "_Znwm", "_Znam", "_ZnwmRKSt9nothrow_t", "_ZnamRKSt9nothrow_t", "_ZnwmSt11align_val_t", "_ZnamSt11align_val_t",
            "_ZnwmSt11align_val_tRKSt9nothrow_t", "_ZnamSt11align_val_tRKSt9nothrow_t",
            "_ZdlPv", "_ZdaPv", "_ZdlPvm", "_ZdaPvm", "_ZdlPvRKSt9nothrow_t", "_ZdaPvRKSt9nothrow_t", "_ZdlPvSt11align_val_t",
            "_ZdaPvSt11align_val_t", "_ZdlPvmSt11align_val_t", "_ZdaPvmSt11align_val_t", "_ZdlPvSt11align_val_tRKSt9nothrow_t",
            "_ZdaPvSt11align_val_tRKSt9nothrow_t",
        };
        void *abi = dlopen("/usr/lib/libc++abi.dylib", RTLD_NOW | RTLD_NOLOAD);
        struct rebinding alloc[sizeof cxxAlloc / sizeof *cxxAlloc]; size_t n = 0;
        for (size_t i = 0; abi && i < sizeof cxxAlloc / sizeof *cxxAlloc; i++) {
            void *system = dlsym(abi, cxxAlloc[i]);
            if (system) alloc[n++] = (struct rebinding){cxxAlloc[i], system, NULL};
        }
        if (n) rebind_symbols(alloc, n);
        NSLog(@"[MacShack] C++ allocator: %zu operator new/delete binds pinned to libc++abi", n);
    });
}
