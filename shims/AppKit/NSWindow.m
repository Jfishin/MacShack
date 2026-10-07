#import "ShackAppKit.h"
#import <pthread.h>
#import "ShackHostView.h"
#import <objc/message.h>

@interface ShackWindowVC : UIViewController @end
@implementation ShackWindowVC
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@protocol ShackWindowDelegate <NSObject> @optional - (void)windowDidBecomeKey:(NSNotification *)n; @end

@implementation NSWindow { ShackHostView *_host; ShackWindowVC *_vc; NSInteger _number; BOOL _visible; CGFloat _alphaValue; NSSize _minSize, _maxSize; NSResponder *_mouseTarget; pthread_t _creator; CFRunLoopRef _creatorLoop; }
static NSInteger gWindowCounter = 1;
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m backing:(NSBackingStoreType)b defer:(BOOL)d screen:(id)screen {
    return [self initWithContentRect:r styleMask:m backing:b defer:d];   // one screen
}
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m backing:(NSBackingStoreType)b defer:(BOOL)d {
    // Every window is shown full-screen. One bigger than the screen gets the screen, as a full-screen Mac window does:
    // a game that sizes its window from the (pixel) display mode (Hades II: 2868x1320) would otherwise get a view that
    // big in points and, at 3x, a Metal drawable nine times the panel (8604x3960; iOS killed it for memory).
    NSSize screen = NSScreen.mainScreen.frame.size;
    if (screen.width > 0 && (r.size.width > screen.width || r.size.height > screen.height)) r = (NSRect){NSZeroPoint, screen};
    if ((self = [super init])) { _frame = r; _styleMask = m; _number = gWindowCounter++; _alphaValue = 1; _shack_mainThreadWindow = NSThread.isMainThread; _creator = pthread_self(); _creatorLoop = CFRunLoopGetCurrent(); }
    return self;
}
- (NSInteger)windowNumber { return _number; }
- (pthread_t)shack_creator { return _creator; }
- (CFRunLoopRef)shack_creatorLoop { return _creatorLoop; }   // not retained: only compared with the app loops, which are
- (ShackHostView *)shack_hostView { return _host; }   // ShackAppKitToggleKeyboard
- (CGFloat)backingScaleFactor { return NSScreen.mainScreen.backingScaleFactor; }
- (NSScreen *)screen { return NSScreen.mainScreen; }
- (BOOL)isKeyWindow { return NSApp.keyWindow == self; }
- (void)setContentView:(NSView *)v {
    _contentView = v; v.nextResponder = self; [v shack_moveToWindow:self];
    if (_host) { UIView *u = v.uiView; [v setFrame:_frame]; ShackMainSync(^{ [self->_host shack_setGuestView:u]; }); }
}
// AppKit: the controller's view becomes the content view and the controller sits between them in the responder chain.
// Crimson Desert installs its Metal view this way, reads it back through contentViewController.view, and takes mouse
// and key events in the controller.
- (void)setContentViewController:(NSViewController *)vc {
    _contentViewController = vc;
    NSView *v = vc.view; self.contentView = v;
    v.nextResponder = vc; vc.nextResponder = self;
}
- (void)makeKeyAndOrderFront:(id)s { [self orderFront:s]; [self makeKeyWindow]; }
// Diagnostic for "black until the app switcher" (open): the scene state and the game view at each transition.
// Big Hops rendered 8,095 drawables with none on glass until a rotation or deactivate/activate; re-requesting landscape
// did not help (the scene already reported landscape), so orientation is not the trigger.
static void logSceneState(NSString *why, UIWindowScene *scene) {
    UIWindow *w = scene.windows.firstObject;
    UIView *host = w.rootViewController.view; CALayer *game = host.subviews.firstObject.layer.sublayers.firstObject;
    NSLog(@"[ShackAppKit] scene %@: state %ld, orientation %ld, window %@ root %@ host %@ game layer %@ %@%@", why, (long)scene.activationState,
          (long)scene.effectiveGeometry.interfaceOrientation, NSStringFromCGRect(w.bounds), NSStringFromClass(w.rootViewController.class),
          NSStringFromCGRect(host.frame), NSStringFromClass(game.class), NSStringFromCGRect(game.frame), game.hidden ? @" hidden" : @"");
}
// Ordered-front windows, back to front (main thread). The front one owns the screen; ordering it out or closing it gives
// the screen and key status back to the one behind, as AppKit does. Crimson Desert shows a splash window as well as its
// game window. A game with one window never sees a difference.
static NSMutableArray<NSWindow *> *gFront;
static UIWindow *GameUIWindow(void) {
    UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
    return scene.windows.firstObject ?: scene.keyWindow;
}
// The window that fills the screen; every other one is occluded, as AppKit reports a window under a full-screen one.
// Chromium (Steam's UI) stops drawing its page while its window is occluded, so Big Picture idles behind a game.
static __unsafe_unretained NSWindow *gOwner;   // always in gFront (which keeps it) or nil; main thread writes
// On the main thread, as AppKit; after the ShackMainSync that ordered them. Chromium's web contents (MacWebContentsOcclusion)
// act only on the notifications its WebContentsOcclusionCheckerMac reposts, marked with its class name; we have no AppKit
// private hook for that checker to repost from, so ours carries the mark.
static void TellOcclusion(NSArray<NSWindow *> *windows) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *w in windows)
            [NSNotificationCenter.defaultCenter postNotificationName:@"NSWindowDidChangeOcclusionStateNotification" object:w
                                                            userInfo:@{@"WebContentsOcclusionCheckerMac": @YES}];
    });
}
static void GiveScreen(UIWindow *w, NSWindow *to) {   // main thread; to has its view controller
    if (w.rootViewController != to->_vc) w.rootViewController = to->_vc;
    NSWindow *from = gOwner;
    if (from == to) return;
    gOwner = to;
    TellOcclusion(from ? @[from, to] : @[to]);
}
- (void)shack_leaveScreen {
    __attribute__((objc_precise_lifetime)) NSWindow *keep = self;   // gFront may hold the last reference
    __block NSWindow *next = nil;
    ShackMainSync(^{
        [gFront removeObject:self];
        UIWindow *w = GameUIWindow();
        if (!self->_vc || w.rootViewController != self->_vc) return;
        next = gFront.lastObject;
        if (next) { GiveScreen(w, next); NSLog(@"[ShackAppKit] window %ld (%@) ordered out; window %ld (%@) has the screen", (long)self->_number, self.class, (long)next->_number, next.class); }
        else if (gOwner == self) { gOwner = nil; TellOcclusion(@[self]); }
    });
    if (!next || NSApp.keyWindow != self) return;
    // Key status and its observers belong to the next window's thread: a game Steam started quits on its own thread, and
    // Chromium (Steam's windows) checks that it hears NSWindowDidBecomeKey on the main thread.
    if (next.shack_mainThreadWindow && !NSThread.isMainThread) dispatch_async(dispatch_get_main_queue(), ^{ [next makeKeyWindow]; });
    else [next makeKeyWindow];
}
- (void)orderFront:(id)s {
    // A window wholly off the screen is invisible on macOS too (Steam's VGUI windows: 1x1 at -15000,-15000): it is
    // ordered in, but never takes the screen from one that shows. One with no size yet still does (sized later).
    if (!_host && !CGRectIsEmpty(_frame) && !CGRectIntersectsRect(_frame, NSScreen.mainScreen.frame)) { _visible = YES; [NSApp shack_addWindow:self]; return; }
    ShackMainSync(^{
        if (!gFront) gFront = [NSMutableArray array];
        [gFront removeObject:self]; [gFront addObject:self];
        if (self->_host) { GiveScreen(GameUIWindow(), self); return; }
        UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
        static dispatch_once_t once; dispatch_once(&once, ^{
            for (NSNotificationName n in @[UISceneWillEnterForegroundNotification, UISceneDidActivateNotification, UISceneWillDeactivateNotification, UISceneDidEnterBackgroundNotification])
                [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                    logSceneState([note.name stringByReplacingOccurrencesOfString:@"UIScene" withString:@""], note.object);
                }];
        });
        logSceneState(@"at game window", scene);
        UIWindow *w = scene.windows.firstObject ?: scene.keyWindow;
        self->_frame = NSScreen.mainScreen.frame;   // fullscreen landscape, whatever the game asked for
        self->_vc = [ShackWindowVC new]; self->_host = [[ShackHostView alloc] initWithFrame:self->_frame]; self->_host.nsWindow = self;
        self->_vc.view = self->_host; GiveScreen(w, self);   // the game takes over the whole screen
        [self->_vc setNeedsUpdateOfSupportedInterfaceOrientations];
        [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape]
                                       errorHandler:^(NSError *e) { NSLog(@"[ShackAppKit] landscape request failed: %@", e); }];
        if (self->_contentView) [self->_host shack_setGuestView:self->_contentView.uiView];
        [self->_host becomeFirstResponder];
        dispatch_async(dispatch_get_main_queue(), ^{ logSceneState(@"after game window", scene); });
    });
    // The content view grows to the screen on the game's own thread, as setContentView: does: a game view subclass reacts
    // to setFrame: with engine work that is only valid there (Valheim opens at 1366x768; resizing it from UIKit's main
    // thread inside the block above stopped Unity with "Graphics device is null").
    if (_contentView) [_contentView setFrame:_frame];
    _visible = YES;
    [NSApp shack_addWindow:self];
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResizeNotification object:self];
}
- (void)makeKeyWindow {
    [NSApp shack_setKeyWindow:self];
    NSNotification *n = [NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:n];
    id<ShackWindowDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(windowDidBecomeKey:)]) [d windowDidBecomeKey:n];
}
- (void)makeMainWindow {}
- (void)close { _visible = NO; [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:self]; [self shack_leaveScreen]; }
- (void)performClose:(id)s { [self close]; }
// As AppKit: the first responder resigns, the new one is asked to become it, and if it declines the window is. Chromium
// takes page focus in its view's becomeFirstResponder (CEF focuses a browser this way; Steam then sends it pad input).
- (BOOL)makeFirstResponder:(NSResponder *)r {
    if (r == _firstResponder) return YES;
    if (_firstResponder && ![_firstResponder resignFirstResponder]) return NO;
    if (r && ![r becomeFirstResponder]) { _firstResponder = self; return NO; }
    _firstResponder = r;
    return YES;
}
- (void)setFrame:(NSRect)r display:(BOOL)d {
    // UIKit stays fullscreen, but AppKit clients must read back the frame they set. Feral emits its own
    // geometry event after calling super; a no-op here left its virtual desktop permanently zero-sized.
    _frame = r;
}
- (void)setFrame:(NSRect)r display:(BOOL)d animate:(BOOL)a { [self setFrame:r display:d]; }
- (void)setFrameOrigin:(NSPoint)p {}
- (void)setContentSize:(NSSize)s {}
// The window is always fullscreen on iOS; toggling only flips the style bit and replays AppKit's
// will/did callbacks (UE4 spins in WaitForFullScreenTransition until windowDidEnterFullScreen: arrives).
- (void)toggleFullScreen:(id)s {
    BOOL enter = !(_styleMask & NSWindowStyleMaskFullScreen);
    [self shack_fullScreenPhase:enter ? @"WillEnter" : @"WillExit"];
    dispatch_async(dispatch_get_main_queue(), ^{   // AppKit finishes after an animation, never inside the call
        if (enter) self->_styleMask |= NSWindowStyleMaskFullScreen; else self->_styleMask &= ~NSWindowStyleMaskFullScreen;
        [self shack_fullScreenPhase:enter ? @"DidEnter" : @"DidExit"];
    });
}
- (void)shack_fullScreenPhase:(NSString *)phase {
    NSNotification *n = [NSNotification notificationWithName:[NSString stringWithFormat:@"NSWindow%@FullScreenNotification", phase] object:self];
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"window%@FullScreen:", phase]);
    id d = self.delegate;
    if ([d respondsToSelector:sel]) ((void (*)(id, SEL, NSNotification *))objc_msgSend)(d, sel, n);
    [NSNotificationCenter.defaultCenter postNotification:n];
}
- (void)center {}
- (NSPoint)cascadeTopLeftFromPoint:(NSPoint)p { return p; }   // one fullscreen window: nothing to cascade (GLFW)
- (void)setAcceptsMouseMovedEvents:(BOOL)f {}

// State the game can set and read back; none of it changes how the (fullscreen) iOS view looks.
- (BOOL)isVisible { return _visible; }
- (BOOL)isMainWindow { return self.isKeyWindow; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isZoomed { return NO; }
- (BOOL)isOnActiveSpace { return YES; }
- (NSUInteger)occlusionState { return self == gOwner ? 1 << 1 : 0; }   // NSWindowOcclusionStateVisible: has the screen (GiveScreen)
- (CGFloat)alphaValue { return _alphaValue; }
- (void)setAlphaValue:(CGFloat)a { _alphaValue = a; }
- (NSRect)frameRectForContentRect:(NSRect)r { return r; }   // borderless: frame == content
- (NSRect)contentRectForFrameRect:(NSRect)r { return r; }
- (NSRect)contentLayoutRect { return (NSRect){NSZeroPoint, _frame.size}; }   // no title bar: the whole content area
+ (NSRect)frameRectForContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m { return r; }
+ (NSRect)contentRectForFrameRect:(NSRect)r styleMask:(NSWindowStyleMask)m { return r; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { return r; }
- (NSRect)convertRectToScreen:(NSRect)r { return r; }   // the window sits at 0,0 on the only screen
- (NSRect)convertRectFromScreen:(NSRect)r { return r; }
- (NSPoint)convertPointToScreen:(NSPoint)p { return p; }
- (NSPoint)convertPointFromScreen:(NSPoint)p { return p; }
- (NSRect)convertRectToBacking:(NSRect)r { CGFloat s = self.backingScaleFactor; return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s); }
- (NSRect)convertRectFromBacking:(NSRect)r { CGFloat s = self.backingScaleFactor; return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s); }
- (NSPoint)mouseLocationOutsideOfEventStream { return NSEvent.mouseLocation; }
- (NSDictionary *)deviceDescription { return self.screen.deviceDescription; }
- (id)colorSpace { return nil; }
- (void)setColorSpace:(id)c {}
- (id)windowController { return nil; }
- (id)fieldEditor:(BOOL)create forObject:(id)o { return nil; }
- (id)standardWindowButton:(NSUInteger)b { return nil; }
- (NSSize)minSize { return _minSize; } - (void)setMinSize:(NSSize)s { _minSize = s; }
- (NSSize)maxSize { return _maxSize; } - (void)setMaxSize:(NSSize)s { _maxSize = s; }
#define NOP(decl) - (void)decl {}
NOP(setOpaque:(BOOL)f) NOP(setBackgroundColor:(id)c) NOP(setHasShadow:(BOOL)f) NOP(setTitlebarAppearsTransparent:(BOOL)f)
NOP(setTitleVisibility:(NSInteger)v) NOP(setMovableByWindowBackground:(BOOL)f) NOP(setMovable:(BOOL)f) NOP(setHidesOnDeactivate:(BOOL)f)
NOP(setRestorable:(BOOL)f) NOP(disableSnapshotRestoration) NOP(setReleasedWhenClosed:(BOOL)f) NOP(setContentMinSize:(NSSize)s)
NOP(setContentMaxSize:(NSSize)s) NOP(setAspectRatio:(NSSize)s) NOP(setContentAspectRatio:(NSSize)s) NOP(miniaturize:(id)s)
NOP(deminiaturize:(id)s) NOP(performMiniaturize:(id)s) NOP(zoom:(id)s) NOP(setDocumentEdited:(BOOL)f) NOP(invalidateShadow) NOP(display)
NOP(displayIfNeeded) NOP(setViewsNeedDisplay:(BOOL)f) NOP(disableFlushWindow) NOP(enableFlushWindow) NOP(setIgnoresMouseEvents:(BOOL)f)
NOP(setAnimationBehavior:(NSInteger)b) NOP(setAutorecalculatesKeyViewLoop:(BOOL)f) NOP(setAllowsConcurrentViewDrawing:(BOOL)f)
NOP(setExcludedFromWindowsMenu:(BOOL)f) NOP(setCanHide:(BOOL)f) NOP(registerForDraggedTypes:(NSArray *)t)
#undef NOP
- (BOOL)hidesOnDeactivate { return NO; }
- (BOOL)ignoresMouseEvents { return NO; }
- (void)orderOut:(id)s { _visible = NO; [self shack_leaveScreen]; }
- (void)orderBack:(id)s { [self orderFront:s]; }
- (void)orderWindow:(NSInteger)place relativeTo:(NSInteger)other { if (place) [self orderFront:nil]; else [self orderOut:nil]; }   // NSWindowOut = 0
- (void)sendEvent:(NSEvent *)e {
    NSResponder *target = _firstResponder ?: _contentView ?: self;
    // Mouse events go to the view under the pointer; a drag and its release stay with the view that took the press.
    NSResponder *hit = [_contentView hitTest:e.locationInWindow] ?: _contentView ?: self;
    switch (e.type) {
        case NSEventTypeLeftMouseDown: case NSEventTypeRightMouseDown: _mouseTarget = hit; break;
        default: break;
    }
    NSResponder *held = _mouseTarget ?: hit;
    switch (e.type) {
        case NSEventTypeLeftMouseDown: [hit mouseDown:e]; break;
        case NSEventTypeLeftMouseUp: [held mouseUp:e]; _mouseTarget = nil; break;
        case NSEventTypeLeftMouseDragged: [held mouseDragged:e]; break;
        case NSEventTypeMouseMoved: [hit mouseMoved:e]; break;
        case NSEventTypeRightMouseDown: [hit rightMouseDown:e]; break;
        case NSEventTypeRightMouseUp: [held rightMouseUp:e]; _mouseTarget = nil; break;
        case NSEventTypeScrollWheel: [hit scrollWheel:e]; break;
        case NSEventTypeKeyDown: [target keyDown:e]; break;
        case NSEventTypeKeyUp: [target keyUp:e]; break;
        case NSEventTypeFlagsChanged: [target flagsChanged:e]; break;
        default: break;
    }
}
@end

// Floating utility windows. ponytail: init answers nil. iOS shows one fullscreen game window (orderFront: hands a
// window the whole screen), and Crimson Desert's only panel, PAOverlayBanner (a spinner/text toast), guards nil and so
// skips its NSStackView and Auto Layout setup, which would need real anchors. Make it a window that is never
// presented when a game needs the panel object itself.
@interface NSPanel : NSWindow @end
@implementation NSPanel
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m backing:(NSBackingStoreType)b defer:(BOOL)d { return nil; }
@end

// The island menu's Keyboard button (host GameOverlay.swift): the iOS keyboard for the game's window.
void ShackAppKitToggleKeyboard(void) {
    ShackMainSync(^{
        NSWindow *w = NSApp.keyWindow ?: NSApp.windows.firstObject;
        [[w valueForKey:@"shack_hostView"] toggleKeyboard];
    });
}

// A second app's end (a game the Steam client started, in-process): the windows its thread made leave the screen, which
// goes back to the window behind them (Steam's).
void ShackAppKitOrderOutWindowsOfThread(pthread_t thread) {
    for (NSWindow *w in [NSApp.windows copy]) if (pthread_equal(w.shack_creator, thread)) [w orderOut:nil];
}

// The ordered-front windows, front first (a guest's CGWindowListCopyWindowInfo: Steam finds its focused window this way).
NSArray<NSWindow *> *ShackAppKitFrontWindows(void) {
    __block NSArray<NSWindow *> *front = @[];
    ShackMainSync(^{ if (gFront) front = gFront.reverseObjectEnumerator.allObjects; });
    return front;
}
