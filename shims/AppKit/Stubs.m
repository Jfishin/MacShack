// Small AppKit classes Unity's player references. The safety net answers anything else.
#import "ShackAppKit.h"

NSString *const NSApplicationDidChangeScreenParametersNotification = @"NSApplicationDidChangeScreenParametersNotification";   // never posted: one fixed screen
NSString *const NSTextInputContextKeyboardSelectionDidChangeNotification = @"NSTextInputContextKeyboardSelectionDidChangeNotification";

@implementation NSViewController { NSView *_view; }
- (instancetype)initWithNibName:(NSString *)name bundle:(NSBundle *)bundle {   // ponytail: no nibs; loadView builds a plain view
    if ((self = [super init])) { _nibName = [name copy]; _nibBundle = bundle; }
    return self;
}
- (instancetype)init { return [self initWithNibName:nil bundle:nil]; }
- (NSView *)view { if (!_view) { [self loadView]; [self viewDidLoad]; } return _view; }
- (void)setView:(NSView *)v { _view = v; v.nextResponder = self; }
- (BOOL)isViewLoaded { return _view != nil; }
- (void)loadView { self.view = [[NSView alloc] initWithFrame:CGRectZero]; }
- (void)viewDidLoad {} - (void)viewWillAppear {} - (void)viewDidAppear {} - (void)viewWillDisappear {} - (void)viewDidDisappear {}
@end

// ponytail: stored, never fires; touches arrive as NSEvents through the window, not through tracking rects.
@interface NSTrackingArea : NSObject
@property (nonatomic, readonly) NSRect rect; @property (nonatomic, readonly) NSUInteger options;
@property (nonatomic, readonly, weak) id owner; @property (nonatomic, readonly, copy) NSDictionary *userInfo;
@end
@implementation NSTrackingArea
SHACK_SAFETY_NET
- (instancetype)initWithRect:(NSRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary *)userInfo {
    if ((self = [super init])) { _rect = rect; _options = options; _owner = owner; _userInfo = [userInfo copy]; }
    return self;
}
@end

// ponytail: no IME; the key events reach interpretKeyEvents: (ShackTextInput.m) without a context.
@interface NSTextInputContext : NSObject @end
@implementation NSTextInputContext
SHACK_SAFETY_NET
+ (NSTextInputContext *)currentInputContext { return nil; }
- (instancetype)initWithClient:(id)client { return [super init]; }
- (BOOL)handleEvent:(id)event { return NO; }
- (void)discardMarkedText {}
- (void)invalidateCharacterCoordinates {}
@end

@interface NSInputManager : NSObject @end
@implementation NSInputManager
SHACK_SAFETY_NET
+ (NSInputManager *)currentInputManager { return nil; }   // ponytail: no IME
@end

// Foundation's; macOS has had no garbage collector since 10.12 and answers nil (GameMaker's runner checks).
@interface NSGarbageCollector : NSObject @end
@implementation NSGarbageCollector
SHACK_SAFETY_NET
+ (id)defaultCollector { return nil; }
@end

// The game itself as a running application (EOS SDK and Hades II ask for it). There is exactly one.
@interface NSRunningApplication : NSObject @end
@implementation NSRunningApplication
SHACK_SAFETY_NET
+ (instancetype)currentApplication { static NSRunningApplication *a; static dispatch_once_t o; dispatch_once(&o, ^{ a = [self new]; }); return a; }
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)bid {
    return [bid isEqualToString:NSBundle.mainBundle.bundleIdentifier] ? @[self.currentApplication] : @[];
}
- (pid_t)processIdentifier { return getpid(); }
- (NSString *)bundleIdentifier { return NSBundle.mainBundle.bundleIdentifier; }
- (NSString *)localizedName { return NSProcessInfo.processInfo.processName; }
- (NSURL *)bundleURL { return NSBundle.mainBundle.bundleURL; }
- (NSURL *)executableURL { return NSBundle.mainBundle.executableURL; }
- (BOOL)isActive { return YES; }
- (BOOL)isHidden { return NO; }
- (BOOL)isTerminated { return NO; }
- (BOOL)isFinishedLaunching { return YES; }
- (NSInteger)activationPolicy { return 0; }   // NSApplicationActivationPolicyRegular
- (BOOL)activateWithOptions:(NSUInteger)options { return YES; }
- (BOOL)hide { return NO; }
- (BOOL)unhide { return YES; }
@end

// Colour spaces by name: SDL2 builds cursor and icon bitmaps in device RGB.
@interface NSColorSpace : NSObject @end
@implementation NSColorSpace { CGColorSpaceRef _cg; }
SHACK_SAFETY_NET
+ (instancetype)deviceRGBColorSpace { static NSColorSpace *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [self new]; c->_cg = CGColorSpaceCreateDeviceRGB(); }); return c; }
+ (instancetype)genericRGBColorSpace { return self.deviceRGBColorSpace; }
// Its own object: guests compare colour spaces by pointer (Factorio converts only reps tagged generic RGB).
+ (instancetype)sRGBColorSpace { static NSColorSpace *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [self new]; c->_cg = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); }); return c; }
- (CGColorSpaceRef)CGColorSpace { return _cg; }
- (NSInteger)numberOfColorComponents { return 3; }
@end

// ponytail: drawing into AppKit graphics contexts (cursor images, message boxes) draws nothing; the game renders with Metal.
@interface NSGraphicsContext : NSObject @end
@implementation NSGraphicsContext
SHACK_SAFETY_NET
@end
@interface NSBezierPath : NSObject @end
@implementation NSBezierPath
SHACK_SAFETY_NET
@end
void NSRectFill(NSRect r) {}

void NSBeep(void) {}

// Godot 4 links these for native file dialogs, dialog option grids and the menu-bar status indicator. ponytail: no
// macOS UI behind them. A panel's runModal answers 0 (NSModalResponseCancel) through the safety net, and a sheet's
// completion handler never runs; build them over UIDocumentPickerViewController if a game needs a real dialog.
@interface NSControl : NSView @end
@implementation NSControl
SHACK_SAFETY_NET
@end
@interface NSButton : NSControl @end
@implementation NSButton
SHACK_SAFETY_NET
@end
@interface NSPopUpButton : NSButton @end
@implementation NSPopUpButton
SHACK_SAFETY_NET
@end
@interface NSTextField : NSControl @end
@implementation NSTextField
SHACK_SAFETY_NET
@end
// The Witcher EE (Virtual Programming eon) links these; it cannot run, but the shells cost nothing.
@interface NSBox : NSView @end
@implementation NSBox
SHACK_SAFETY_NET
@end
@interface NSProgressIndicator : NSView @end
@implementation NSProgressIndicator
SHACK_SAFETY_NET
@end
@interface NSScroller : NSControl @end
@implementation NSScroller
SHACK_SAFETY_NET
@end
@interface NSSlider : NSControl @end
@implementation NSSlider
SHACK_SAFETY_NET
@end
@interface NSTabView : NSView @end
@implementation NSTabView
SHACK_SAFETY_NET
@end
@interface NSTableView : NSControl @end
@implementation NSTableView
SHACK_SAFETY_NET
@end
@interface NSGridView : NSView @end
@implementation NSGridView
SHACK_SAFETY_NET
@end
@interface NSSavePanel : NSObject @end
@implementation NSSavePanel
SHACK_SAFETY_NET
+ (instancetype)savePanel { return [self new]; }
@end
@interface NSOpenPanel : NSSavePanel @end
@implementation NSOpenPanel
+ (instancetype)openPanel { return [self new]; }
@end
@interface NSStatusBar : NSObject @end
@implementation NSStatusBar
SHACK_SAFETY_NET
+ (instancetype)systemStatusBar { static NSStatusBar *b; static dispatch_once_t o; dispatch_once(&o, ^{ b = [self new]; }); return b; }
@end

// Godot 4.5: dark-mode probe (NSAppearance; nil answers mean light), text-to-speech (NSSpeechSynthesizer), and its
// GL compatibility renderer's CAOpenGLLayer subclass, which must exist to load even when the Metal/Vulkan path is used.
// QuartzCore binds are routed here (LINK_MAP) with QuartzCore re-exported. ponytail: safety-net shells.
@interface NSAppearance : NSObject @end
@implementation NSAppearance
SHACK_SAFETY_NET
@end
@interface NSSpeechSynthesizer : NSObject @end
@implementation NSSpeechSynthesizer
SHACK_SAFETY_NET
@end
@interface CAOpenGLLayer : CALayer @end
@implementation CAOpenGLLayer @end
NSString *const kCAContextCIFilterBehavior = @"CIFilterBehavior";   // value from macOS QuartzCore

// NSScriptingComparisonMethods, an NSObject category on macOS (CoronaCards' AppDelegate compares strings with isEqualTo:).
@interface NSObject (ShackScriptingComparison) @end
@implementation NSObject (ShackScriptingComparison)
- (BOOL)isEqualTo:(id)object { return [self isEqual:object]; }
- (BOOL)isNotEqualTo:(id)object { return ![self isEqual:object]; }
@end

// Classes Feral Interactive's launcher (BioShock Remastered) links against for its native pre-game windows and sharing
// menu. The game guards most of them and draws its UI in a WebView; they exist so the binary loads, and draw nothing.
NSString *const NSSharingServiceNamePostOnFacebook = @"com.apple.share.Facebook.window";
NSString *const NSSharingServiceNamePostOnTwitter = @"com.apple.share.Twitter.window";
void NSDisableScreenUpdates(void) {}   // deprecated flicker guards: one compositor, nothing to hold back
void NSEnableScreenUpdates(void) {}

@interface NSImageView : NSView @property (nonatomic, strong) id image; @property (nonatomic, getter=isEditable) BOOL editable; @end
@implementation NSImageView SHACK_SAFETY_NET @end
@interface NSTableCellView : NSView @property (nonatomic, strong) id imageView; @property (nonatomic, strong) id textField; @end
@implementation NSTableCellView SHACK_SAFETY_NET @end
@interface NSWindowController : NSResponder
@property (nonatomic, strong) NSWindow *window; @property (nonatomic, copy) NSString *windowNibName; @property (nonatomic, weak) id owner;
@end
@implementation NSWindowController
SHACK_SAFETY_NET
- (instancetype)initWithWindow:(NSWindow *)window { if ((self = [super init])) _window = window; return self; }
- (instancetype)initWithWindowNibName:(NSString *)name { if ((self = [super init])) _windowNibName = [name copy]; return self; }
- (instancetype)initWithWindowNibName:(NSString *)name owner:(id)owner { if ((self = [self initWithWindowNibName:name])) _owner = owner; return self; }
- (void)showWindow:(id)sender { [self.window makeKeyAndOrderFront:sender]; }
- (void)close { [self.window close]; }
@end
@interface NSNib : NSObject @end   // ponytail: nibs beyond the main one are not instantiated (ShackNib.m reads MainMenu only)
@implementation NSNib
SHACK_SAFETY_NET
- (instancetype)initWithNibNamed:(NSString *)name bundle:(NSBundle *)bundle { return [super init]; }
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)objects { if (objects) *objects = @[]; return NO; }
@end
@interface NSSound : NSObject @property (nonatomic) float volume; @property (nonatomic) BOOL loops; @end   // ponytail: interface sounds stay silent
@implementation NSSound
SHACK_SAFETY_NET
+ (instancetype)soundNamed:(NSString *)name { return nil; }
- (instancetype)initWithContentsOfFile:(NSString *)path byReference:(BOOL)byRef { return [super init]; }
- (BOOL)play { return YES; } - (BOOL)stop { return YES; } - (BOOL)isPlaying { return NO; }
@end
// Crimson Desert's overlay banner links these; its NSPanel init gets nil (NSWindow.m), so they only need to exist.
// ponytail: safety-net shells. runAnimationGroup: runs no blocks, stackViewWithViews: answers nil.
@interface NSStackView : NSView @end
@implementation NSStackView SHACK_SAFETY_NET @end
@interface NSVisualEffectView : NSView @end
@implementation NSVisualEffectView SHACK_SAFETY_NET @end
@interface NSAnimationContext : NSObject @end
@implementation NSAnimationContext SHACK_SAFETY_NET @end

@interface NSSharingService : NSObject @end
@implementation NSSharingService
SHACK_SAFETY_NET
+ (instancetype)sharingServiceNamed:(NSString *)name { return nil; }   // no services on iOS: a game hides its share button
@end
