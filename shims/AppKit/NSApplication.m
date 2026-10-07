#import "ShackAppKit.h"
#import "ShackTerminate.h"
#import <pthread.h>
NSApplication *NSApp;

// Threading, as on a Mac: the thread that calls -run is the app thread. Delegate callbacks run on it synchronously, -run
// then spins its run loop (timers the delegate schedules fire there), and events from UIKit hop onto it, so a game handles
// input on the same thread as its loop. Hades II needs this (its loop runs inside applicationDidFinishLaunching: and
// relies on thread-locals set up in main()). SHACK_APP_THREAD=main keeps the older model, the delegate on UIKit's main
// thread, for engines built around it (the loader sets it for Unreal, which runs its game on a thread of its own).
NSArray *ShackNibLaunchWindows(void);   // ShackNib.m
@implementation NSApplication { NSMutableArray<NSWindow *> *_windows; NSWindow *_key; dispatch_semaphore_t _forever; NSEvent *_current; CFRunLoopRef _appLoop; NSMutableArray<NSEvent *> *_pumpQueue; BOOL _pumping; CFRunLoopRef _pumpLoop; CFRunLoopSourceRef _pumpWake; BOOL _running; }
+ (NSApplication *)sharedApplication {
    static dispatch_once_t o; dispatch_once(&o, ^{ NSApp = [self new]; });
    return NSApp;
}
- (instancetype)init { if ((self = [super init])) { _windows = [NSMutableArray array]; _pumpQueue = [NSMutableArray array]; _forever = dispatch_semaphore_create(0); } return self; }
- (NSArray<NSWindow *> *)windows { return _windows; }
- (NSWindow *)keyWindow { return _key; }
- (CFRunLoopRef)shack_appLoop { return _appLoop ?: CFRunLoopGetMain(); }
// Every app thread's loop: the Steam client's, then a game's it started in this process (each pumps its own events,
// as two Mac apps would). _appLoop is the newest; the game's took Steam's slot, so steam_osx's own pump got nil at once
// and spun a core, and Steam's events went to the game's thread even after the game ended (2026-10-04).
static CFRunLoopRef gAppLoops[4]; static _Atomic int gAppLoopCount;   // append-only, retained
static void NoteAppLoop(CFRunLoopRef l) {
    for (int i = 0; i < gAppLoopCount; i++) if (gAppLoops[i] == l) return;
    if (gAppLoopCount < 4) { gAppLoops[gAppLoopCount] = (CFRunLoopRef)CFRetain(l); gAppLoopCount++; }
}
BOOL ShackAppKitIsAppLoop(CFRunLoopRef l) { for (int i = 0; i < gAppLoopCount; i++) if (gAppLoops[i] == l) return YES; return NO; }
// The Steam client's game ended: the first app thread (steam_osx's) is the app thread again.
void ShackAppKitRestoreAppLoop(void) { if (gAppLoopCount) NSApp->_appLoop = gAppLoops[0]; }
static BOOL UIKitMainModel(void);
- (void)shack_adoptAppThread { if (!UIKitMainModel() && !_appLoop) { _appLoop = CFRunLoopGetCurrent(); NoteAppLoop(_appLoop); } }
- (NSWindow *)mainWindow { return _key; }
// NSApp state is only mutated on main, where sendEvent: reads it.
- (void)shack_addWindow:(NSWindow *)w { ShackMainSync(^{ if (![self->_windows containsObject:w]) [self->_windows addObject:w]; }); }
- (void)shack_setKeyWindow:(NSWindow *)w { ShackMainSync(^{ self->_key = w; }); }

static BOOL UIKitMainModel(void) { const char *v = getenv("SHACK_APP_THREAD"); return v && !strcmp(v, "main"); }
- (void)finishLaunching {
    NSNotification *n = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
    void (^launch)(void) = ^{
        if ([self.delegate respondsToSelector:@selector(applicationWillFinishLaunching:)]) [self.delegate applicationWillFinishLaunching:n];
        if ([self.delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) [self.delegate applicationDidFinishLaunching:n];
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidFinishLaunchingNotification object:self];
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:self];
        // The main nib's windows are shown at launch, as AppKit does for a window marked visible at launch.
        for (NSWindow *w in ShackNibLaunchWindows()) [w makeKeyAndOrderFront:nil];
    };
    if (!UIKitMainModel()) { _appLoop = CFRunLoopGetCurrent(); NoteAppLoop(_appLoop); launch(); return; }
    // Older model: the delegate on UIKit's main thread. A run-loop block, not a main-queue block: a delegate that never
    // returns would keep the GCD main queue busy forever and every dispatch_sync to main would deadlock.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, launch);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
static void KeepAlive(void *info) {}
- (void)run {
    // Feral's launcher (Batman) runs [NSApp run] again from a delayed perform on the main thread, a nested event loop
    // in AppKit. In the older model that is UIKit's main thread: a nested run loop there, never the park below.
    if (_running && UIKitMainModel() && NSThread.isMainThread) {
        NSLog(@"[ShackAppKit] -[NSApplication run] again on UIKit's main thread: a nested run loop");
        for (;;) @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e9, false); }
    }
    _running = YES;
    [self finishLaunching];
    if (UIKitMainModel()) {
        NSLog(@"[ShackAppKit] -[NSApplication run]: parking guest main thread (delegate on UIKit's main thread)");
        dispatch_semaphore_wait(_forever, DISPATCH_TIME_FOREVER);   // ponytail: no terminate path yet; iOS kills the process instead
    }
    NSLog(@"[ShackAppKit] -[NSApplication run]: app run loop on the guest main thread");
    CFRunLoopSourceContext ctx = { .perform = KeepAlive };   // a loop with no sources returns at once
    CFRunLoopSourceRef keep = CFRunLoopSourceCreate(NULL, 0, &ctx); CFRunLoopAddSource(CFRunLoopGetCurrent(), keep, kCFRunLoopCommonModes);
    for (;;) @autoreleasepool { CFRunLoopRun(); }
}
- (void)sendEvent:(NSEvent *)e {
    // A window made on UIKit's main thread is handled there: Steam Helper runs in-process with steam_osx (the app
    // thread), and its Chromium checks that its views get events on the main thread.
    NSWindow *w = e.window ?: _key; CFRunLoopRef made = w.shack_creatorLoop;   // the app thread that made the window
    CFRunLoopRef app = w.shack_mainThreadWindow ? CFRunLoopGetMain() : made && ShackAppKitIsAppLoop(made) ? made : _appLoop;
    if (app && CFRunLoopGetCurrent() != app) {   // from UIKit: handle it on the app thread, between the game's own work
        CFRunLoopPerformBlock(app, kCFRunLoopCommonModes, ^{ [self sendEvent:e]; }); CFRunLoopWakeUp(app);
        return;
    }
    _current = e;
    if (!(e = [NSEvent shack_runLocalMonitors:e])) return;
    [(e.window ?: _key) sendEvent:e];
}
// CGEventPost's key events (libShackCG): on a Mac they reach the key window of the app in front, as from a keyboard.
// Steam's on-screen keyboard types this way, from steamclient's IPC thread (sendEvent: hops to the window's thread).
__attribute__((visibility("default"))) void ShackAppKitPostKey(unsigned short keyCode, NSString *characters, BOOL down) {
    NSWindow *w = NSApp.keyWindow;
    NSEvent *e = [NSEvent new]; e.type = down ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    e.window = w; e.windowNumber = w.windowNumber; e.timestamp = NSProcessInfo.processInfo.systemUptime;
    e.keyCode = keyCode; e.modifierFlags = NSEvent.modifierFlags;
    e.characters = characters; e.charactersIgnoringModifiers = characters.lowercaseString; e.isARepeat = NO;
    e.locationInWindow = NSEvent.mouseLocation;
    [NSApp sendEvent:e];
}
- (void)activateIgnoringOtherApps:(BOOL)f {}
- (void)activate {}
- (BOOL)isActive { return YES; }
- (void)hide:(id)s {} - (void)unhide:(id)s {}
- (void)terminate:(id)s { NSLog(@"[ShackAppKit] terminate:"); ShackTerminateBegin(self, self.delegate, ^{ exit(0); }); }
- (void)replyToApplicationShouldTerminate:(BOOL)f { ShackTerminateReply(f, self, self.delegate, ^{ exit(0); }); }
// MacShack's quit button: the delegate expects terminate: on the app thread (UIKit's main thread in the older model).
- (void)shack_requestQuit {
    CFRunLoopRef loop = _appLoop ?: CFRunLoopGetMain();
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [self terminate:nil]; });
    CFRunLoopWakeUp(loop);
}
- (BOOL)setActivationPolicy:(NSInteger)p { return YES; }
- (void)setPresentationOptions:(NSUInteger)o { _presentationOptions = o; }
- (BOOL)isRunning { return YES; }
- (BOOL)isHidden { return NO; }
- (NSInteger)activationPolicy { return 0; }   // NSApplicationActivationPolicyRegular
- (NSEvent *)currentEvent { return _current; }
// Events from UIKit are delivered to sendEvent: directly. A game that pumps its own loop (Hades II, Feral's engines) calls this on the
// app thread (or UIKit's main thread in the older model): run that thread's loop until `d`, which is where timers and main-queue work
// get their turn. What such a game posts comes back from here, as in AppKit: Feral wakes its main thread with an NSApplicationDefined
// event and runs its main-thread tasks only when the pump returns it. Until a game first pumps, a posted event goes straight to
// sendEvent: (the -run model).
static void PumpWake(void *info) {}
static pthread_mutex_t gPumpLock = PTHREAD_MUTEX_INITIALIZER;
- (NSEvent *)shack_takeQueued:(NSEventMask)m dequeue:(BOOL)dq {
    NSEvent *found = nil;
    pthread_mutex_lock(&gPumpLock);
    _pumping = YES;
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    if (_pumpLoop != loop) {   // a source, not CFRunLoopStop: a post that lands before the loop starts still ends its wait
        if (!_pumpWake) { CFRunLoopSourceContext ctx = { .perform = PumpWake }; _pumpWake = CFRunLoopSourceCreate(NULL, 0, &ctx); }
        CFRunLoopAddSource(loop, _pumpWake, kCFRunLoopCommonModes);
        _pumpLoop = loop;
    }
    for (NSUInteger i = 0; i < _pumpQueue.count && !found; i++) {
        NSEvent *e = _pumpQueue[i];
        if (m & (1ULL << e.type)) { found = e; if (dq) [_pumpQueue removeObjectAtIndex:i]; }
    }
    pthread_mutex_unlock(&gPumpLock);
    return found;
}
- (NSEvent *)nextEventMatchingMask:(NSEventMask)m untilDate:(NSDate *)d inMode:(NSString *)mode dequeue:(BOOL)dq {
    static dispatch_once_t o; dispatch_once(&o, ^{ NSLog(@"[ShackAppKit] nextEventMatchingMask: pumps the app thread's run loop; events arrive via sendEvent:, posted ones from here"); });
    if (!(ShackAppKitIsAppLoop(CFRunLoopGetCurrent()) || NSThread.isMainThread)) return nil;
    for (;;) {
        NSEvent *e = [self shack_takeQueued:m dequeue:dq];
        if (e) return e;
        NSTimeInterval left = d ? d.timeIntervalSinceNow : 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, MAX(0, left), true);
        if (left <= 0) return [self shack_takeQueued:m dequeue:dq];
    }
}
- (void)postEvent:(NSEvent *)e atStart:(BOOL)f {
    if (!e) return;
    CFRunLoopRef loop = NULL;
    pthread_mutex_lock(&gPumpLock);
    if (_pumping) { if (f) [_pumpQueue insertObject:e atIndex:0]; else [_pumpQueue addObject:e]; loop = _pumpLoop; }
    pthread_mutex_unlock(&gPumpLock);
    if (loop) { CFRunLoopSourceSignal(_pumpWake); CFRunLoopWakeUp(loop); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ [self sendEvent:e]; });
}
- (NSWindow *)windowWithWindowNumber:(NSInteger)n { for (NSWindow *w in _windows) if (w.windowNumber == n) return w; return nil; }
- (void)enumerateWindowsWithOptions:(NSInteger)o usingBlock:(void (^)(NSWindow *, BOOL *))b { BOOL stop = NO; for (NSWindow *w in [_windows copy]) { b(w, &stop); if (stop) break; } }
- (NSInteger)runModalForWindow:(NSWindow *)w { return 0; }
- (id)dockTile { return nil; }
#define NOP(decl) - (void)decl {}
NOP(updateWindows) NOP(stop:(id)s) NOP(abortModal) NOP(stopModal) NOP(orderFrontStandardAboutPanel:(id)s) NOP(hideOtherApplications:(id)s)
NOP(preventWindowOrdering) NOP(addWindowsItem:(NSWindow *)w title:(NSString *)t filename:(BOOL)f) NOP(changeWindowsItem:(NSWindow *)w title:(NSString *)t filename:(BOOL)f)
NOP(requestUserAttention:(NSInteger)t) NOP(cancelUserAttentionRequest:(NSInteger)r)
#undef NOP
@end

// Called by the host's quit panel (GameOverlay.swift): the game gets the Mac quit sequence and saves before it exits.
void ShackAppKitRequestQuit(void) { if (NSApp) [NSApp shack_requestQuit]; else exit(0); }

NSString *ShackNibDelegateClass(NSString *nibPath, NSString *appClass);   // ShackNib.m: plist or NIBArchive nibs
void ShackNibConnect(NSString *nibPath, id delegate, NSString *delegateName);
NSArray *ShackNibLaunchWindows(void);   // the windows the main nib built

// ponytail: of the main nib the application's delegate, and the window/views connected to it (Solar2D's CoronaView), are
// honored; menus and controls are dropped. Read more of the archive when a guest needs it.
static id MainNibDelegate(NSString *nibPath, NSString *appClass) {
    NSString *name = ShackNibDelegateClass(nibPath, appClass);
    Class cls = name ? NSClassFromString(name) : nil;
    NSLog(@"[ShackAppKit] main nib %@: delegate %@", nibPath.lastPathComponent, name ?: @"(none)");
    id delegate = [cls new];
    if (delegate) ShackNibConnect(nibPath, delegate, name);
    return delegate;
}

void ShackNibInstallMainMenu(NSString *nibPath);   // NSMenu.m

// NSPrincipalClass and NSMainNibFile from the guest's Info.plist, as AppKit's NSApplicationMain does.
int NSApplicationMain(int argc, const char *argv[]) {
    NSString *contents = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]];
    Class principal = NSClassFromString(info[@"NSPrincipalClass"]) ?: NSApplication.class;
    NSApplication *app = [(Class)principal performSelector:@selector(sharedApplication)];
    // A second app on a thread of its own (a game the Steam client starts, beside Steam): it gets its nib and delegate
    // too, and its -run makes its thread the app thread.
    BOOL second = app.delegate && app.shack_appLoop != CFRunLoopGetCurrent();
    [app shack_adoptAppThread];   // views the nib builds draw on this thread
    static id delegate;   // delegate is weak; the nib would own its top-level objects
    NSString *nib = info[@"NSMainNibFile"];
    if ((!app.delegate || second) && nib) {
        // Resources/X.nib, else a localized copy (Base.lproj first, then English, then any language)
        NSString *res = [contents stringByAppendingPathComponent:@"Resources"], *path = [res stringByAppendingFormat:@"/%@.nib", nib];
        NSMutableArray *lprojs = [@[@"Base.lproj", @"en.lproj", @"English.lproj"] mutableCopy];
        for (NSString *e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:res error:nil]) if ([e hasSuffix:@".lproj"]) [lprojs addObject:e];
        for (NSString *l in lprojs) {
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) break;
            path = [res stringByAppendingFormat:@"/%@/%@.nib", l, nib];
        }
        delegate = MainNibDelegate(path, NSStringFromClass(principal));
        app.delegate = delegate;
        ShackNibInstallMainMenu(path);   // the menu bar a keyed-archive nib describes (Feral's engine reads it at startup)
    }
    [app run];
    return 0;
}
