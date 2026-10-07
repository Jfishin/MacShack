#import <pthread.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// AppKit geometry aliases. iOS Foundation exports NSZeroPoint/NSStringFromRect but its headers omit them.
typedef CGPoint NSPoint; typedef CGSize NSSize; typedef CGRect NSRect;
FOUNDATION_EXPORT const NSPoint NSZeroPoint;
FOUNDATION_EXPORT NSString *NSStringFromRect(NSRect r);
static inline NSPoint NSMakePoint(CGFloat x, CGFloat y) { return CGPointMake(x, y); }
static inline NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return CGRectMake(x, y, w, h); }

extern NSString *const NSEventTrackingRunLoopMode;
extern NSString *const NSModalPanelRunLoopMode;
extern NSString *const NSApplicationDidFinishLaunchingNotification;
extern NSString *const NSApplicationDidBecomeActiveNotification;
extern NSString *const NSApplicationWillResignActiveNotification;
extern NSString *const NSWindowDidResizeNotification;
extern NSString *const NSWindowDidBecomeKeyNotification;
extern NSString *const NSWindowWillCloseNotification;
extern const double NSAppKitVersionNumber;
extern NSString *const NSAccessibilityAnnouncementKey, *const NSAccessibilityAnnouncementRequestedNotification, *const NSAccessibilityButtonRole,
    *const NSAccessibilityCheckBoxRole, *const NSAccessibilityComboBoxRole, *const NSAccessibilityImageRole, *const NSAccessibilityLayoutAreaRole,
    *const NSAccessibilityLinkRole, *const NSAccessibilityPriorityKey, *const NSAccessibilitySecureTextFieldSubrole, *const NSAccessibilitySliderRole,
    *const NSAccessibilityStaticTextRole, *const NSAccessibilityTextFieldRole, *const NSAccessibilityTextLinkSubrole,
    *const NSAccessibilityUIElementDestroyedNotification, *const NSAccessibilityUnknownRole, *const NSAccessibilityValueChangedNotification,
    *const NSAccessibilityWindowRole, *const NSPasteboardTypeFileURL, *const NSPasteboardTypeString,
    *const NSWindowDidEndLiveResizeNotification, *const NSWindowDidEnterFullScreenNotification, *const NSWindowDidExitFullScreenNotification,
    *const NSWindowWillStartLiveResizeNotification, *const NSWorkspaceActiveSpaceDidChangeNotification;
extern NSString *NSCalibratedRGBColorSpace, *NSViewBoundsDidChangeNotification, *NSViewFrameDidChangeNotification, *NSWindowDidMoveNotification,
    *NSWindowWillMoveNotification, *NSWorkspaceSessionDidBecomeActiveNotification, *NSWorkspaceSessionDidResignActiveNotification;
NSString *NSAccessibilityRoleDescription(NSString *role, NSString *subrole);
void NSAccessibilityPostNotification(id element, NSString *notification);
void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *userInfo);
NSInteger NSRunInformationalAlertPanel(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...) NS_FORMAT_FUNCTION(2,6);

typedef NS_OPTIONS(NSUInteger, NSWindowStyleMask) { NSWindowStyleMaskBorderless = 0, NSWindowStyleMaskTitled = 1, NSWindowStyleMaskClosable = 2, NSWindowStyleMaskMiniaturizable = 4, NSWindowStyleMaskResizable = 8, NSWindowStyleMaskFullScreen = 1 << 14 };
typedef NS_ENUM(NSUInteger, NSBackingStoreType) { NSBackingStoreBuffered = 2 };
typedef NS_ENUM(NSUInteger, NSEventType) { NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2, NSEventTypeRightMouseDown = 3, NSEventTypeRightMouseUp = 4, NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6, NSEventTypeRightMouseDragged = 7, NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12, NSEventTypeScrollWheel = 22 };
typedef unsigned long long NSEventMask;   // bit (1 << NSEventType)
typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) { NSEventModifierFlagCapsLock = 1 << 16, NSEventModifierFlagShift = 1 << 17, NSEventModifierFlagControl = 1 << 18, NSEventModifierFlagOption = 1 << 19, NSEventModifierFlagCommand = 1 << 20, NSEventModifierFlagFunction = 1 << 23 };

// Unknown-selector safety net (ShackSafetyNet.m). Forwarding, not +resolveInstanceMethod:, so respondsToSelector:
// and KVC probes stay truthful (a resolver answers YES to every probe). An unknown message is logged once per
// class+selector and returns zero. ponytail: the return type is guessed as id, so a struct/float-returning
// selector gets garbage; implement those for real when they show in the log. Skips `_`/`shack_` selectors.
NSMethodSignature *ShackStubSignature(SEL sel);
void ShackStubInvoke(id self, NSInvocation *inv);
#define SHACK_SAFETY_NET \
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \
- (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); } \
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \
+ (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); }

// Springs and struts (ShackLayout.m): one axis after the parent resized; a layer's sublayers after it resized.
CGFloat ShackResized(CGFloat pos, CGFloat len, CGFloat oldParent, CGFloat newParent, NSUInteger minMargin, NSUInteger size, NSUInteger maxMargin, NSUInteger mask, CGFloat *outLen);
void ShackResizeSublayers(CALayer *l, CGSize old);
static inline void ShackMainSync(dispatch_block_t b) { if (NSThread.isMainThread) b(); else dispatch_sync(dispatch_get_main_queue(), b); }

@class NSWindow, NSView, NSEvent, NSApplication;

@interface NSResponder : NSObject
@property (nonatomic, weak) NSResponder *nextResponder;
- (BOOL)acceptsFirstResponder; - (BOOL)becomeFirstResponder; - (BOOL)resignFirstResponder;
- (void)mouseDown:(NSEvent *)e; - (void)mouseUp:(NSEvent *)e; - (void)mouseDragged:(NSEvent *)e; - (void)mouseMoved:(NSEvent *)e;
- (void)rightMouseDown:(NSEvent *)e; - (void)rightMouseUp:(NSEvent *)e; - (void)scrollWheel:(NSEvent *)e;
- (void)keyDown:(NSEvent *)e; - (void)keyUp:(NSEvent *)e; - (void)flagsChanged:(NSEvent *)e;
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events; - (void)doCommandBySelector:(SEL)s;
@end

@interface NSEvent : NSObject
@property (nonatomic) NSEventType type; @property (nonatomic) NSPoint locationInWindow; @property (nonatomic) NSEventModifierFlags modifierFlags;
@property (nonatomic) NSTimeInterval timestamp; @property (nonatomic, weak) NSWindow *window; @property (nonatomic) NSInteger windowNumber;
@property (nonatomic) unsigned short keyCode; @property (nonatomic, copy) NSString *characters; @property (nonatomic, copy) NSString *charactersIgnoringModifiers; @property (nonatomic) BOOL isARepeat;
@property (nonatomic) CGFloat deltaX, deltaY, scrollingDeltaX, scrollingDeltaY; @property (nonatomic) NSInteger buttonNumber, clickCount;
@property (nonatomic) short subtype; @property (nonatomic) NSInteger data1, data2; @property (nonatomic, readonly) NSInteger eventNumber;
+ (void)shack_setPressedMouseButtons:(NSUInteger)b; + (void)shack_setModifierFlags:(NSEventModifierFlags)m; + (NSEventModifierFlags)modifierFlags;
+ (NSPoint)mouseLocation;
+ (void)shack_setMouseLocation:(NSPoint)p;
+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(NSEvent *(^)(NSEvent *))h;
+ (id)addGlobalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(void (^)(NSEvent *))h;
+ (void)removeMonitor:(id)m;
+ (NSEvent *)shack_runLocalMonitors:(NSEvent *)e;   // main thread; nil if a monitor swallowed it
@end

@interface NSScreen : NSObject
+ (NSScreen *)mainScreen; + (NSArray<NSScreen *> *)screens;
@property (nonatomic, readonly) NSRect frame, visibleFrame; @property (nonatomic, readonly) CGFloat backingScaleFactor;
@property (nonatomic, readonly) NSDictionary *deviceDescription;
@end

@interface NSView : NSResponder
@property (nonatomic, readonly) UIView *uiView;           // created on main thread on first access
@property (nonatomic) NSRect frame, bounds; @property (nonatomic, weak) NSWindow *window; @property (nonatomic, weak) NSView *superview;
@property (nonatomic, strong) CALayer *layer; @property (nonatomic) BOOL wantsLayer; @property (nonatomic, getter=isHidden) BOOL hidden;
- (CALayer *)makeBackingLayer; - (CGRect)uiFrame;
- (instancetype)initWithFrame:(NSRect)r; - (void)addSubview:(NSView *)v; - (void)setNeedsDisplay:(BOOL)f; - (void)setAutoresizingMask:(NSUInteger)m;
- (NSView *)hitTest:(NSPoint)p; - (void)shack_applyFrame:(NSRect)r; - (void)shack_syncUIFrame;
- (void)shack_moveToWindow:(NSWindow *)w;   // window set on the view and its subviews, viewDidMoveToWindow sent, first display queued
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v; - (BOOL)isFlipped;
@end

@interface NSViewController : NSResponder
@property (nonatomic, strong) NSView *view; @property (nonatomic, strong) id representedObject;
@property (nonatomic, readonly, copy) NSString *nibName; @property (nonatomic, readonly, strong) NSBundle *nibBundle;
@end

@interface NSWindow : NSResponder
@property (nonatomic, strong) NSView *contentView; @property (nonatomic, strong) NSViewController *contentViewController; @property (nonatomic, copy) NSString *title; @property (nonatomic) NSWindowStyleMask styleMask;
@property (nonatomic) NSRect frame; @property (nonatomic, weak) id delegate; @property (nonatomic, readonly) CGFloat backingScaleFactor;
@property (nonatomic, readonly) NSScreen *screen; @property (nonatomic, readonly) NSInteger windowNumber; @property (nonatomic) NSInteger level;
@property (nonatomic, readonly) BOOL isKeyWindow; @property (nonatomic, weak) NSResponder *firstResponder;
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m backing:(NSBackingStoreType)b defer:(BOOL)d;
- (void)makeKeyAndOrderFront:(id)s; - (void)orderFront:(id)s; - (void)makeKeyWindow; - (void)makeMainWindow; - (void)close;
- (BOOL)makeFirstResponder:(NSResponder *)r; - (void)setFrame:(NSRect)r display:(BOOL)d; - (void)toggleFullScreen:(id)s; - (void)center;
- (void)setAcceptsMouseMovedEvents:(BOOL)f; - (void)sendEvent:(NSEvent *)e; - (void)setContentSize:(NSSize)s;
// Made on UIKit's main thread (Steam Helper's windows, in-process with steam_osx): its events are handled there.
@property (nonatomic, readonly) BOOL shack_mainThreadWindow;
@property (nonatomic, readonly) pthread_t shack_creator;   // the thread that made it
@property (nonatomic, readonly) CFRunLoopRef shack_creatorLoop;   // and its run loop
@property (nonatomic, weak) NSResponder *initialFirstResponder; @property (nonatomic) NSUInteger collectionBehavior;
// macOS 13: SDL 2.28+ confines the cursor through it whenever a window gains focus (Pepper Grinder). Stored for read-back:
// iOS has no cursor. A missing method here crashed that Intel game inside AArchX's forwarded send (NSRect argument).
@property (nonatomic) NSRect mouseConfinementRect; @property (nonatomic, readonly) NSRect contentLayoutRect;
@end

@protocol NSApplicationDelegate <NSObject> @optional
- (void)applicationWillFinishLaunching:(NSNotification *)n; - (void)applicationDidFinishLaunching:(NSNotification *)n;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a;
@end

@interface NSApplication : NSResponder
+ (NSApplication *)sharedApplication; @property (nonatomic, weak) id<NSApplicationDelegate> delegate;
@property (nonatomic, readonly) NSWindow *keyWindow, *mainWindow; @property (nonatomic, readonly) NSArray<NSWindow *> *windows;
- (void)run; - (void)finishLaunching; - (void)sendEvent:(NSEvent *)e; - (void)activateIgnoringOtherApps:(BOOL)f; - (void)activate;
- (void)terminate:(id)s; - (BOOL)setActivationPolicy:(NSInteger)p; - (void)setPresentationOptions:(NSUInteger)o;
- (BOOL)isActive; - (void)hide:(id)s; - (void)unhide:(id)s;
- (void)shack_addWindow:(NSWindow *)w; - (void)shack_setKeyWindow:(NSWindow *)w;
- (CFRunLoopRef)shack_appLoop;   // the app thread's run loop, where views draw
- (void)shack_adoptAppThread;    // the calling thread is the app thread (NSApplicationMain, before the nib builds views)
@property (nonatomic, strong) id mainMenu, windowsMenu, servicesMenu, applicationIconImage; @property (nonatomic, readonly) NSUInteger presentationOptions;
@end
extern NSApplication *NSApp;
int NSApplicationMain(int argc, const char *argv[]);
