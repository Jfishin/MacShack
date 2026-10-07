#import "ShackAppKit.h"

NSString *const NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";
NSString *const NSModalPanelRunLoopMode = @"NSModalPanelRunLoopMode";
NSString *const NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
NSString *const NSApplicationWillResignActiveNotification = @"NSApplicationWillResignActiveNotification";
NSString *const NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";   // named only, never posted
NSString *const NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
NSString *const NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
NSString *const NSWindowWillCloseNotification = @"NSWindowWillCloseNotification";
const double NSAppKitVersionNumber = 2487; // macOS 15-era value; games compare against old thresholds

// Names match macOS; const-ness matches the macOS headers (some are non-const there).
#define K(n) NSString *const n = @#n;
#define KV(n) NSString *n = @#n;
K(NSAccessibilityAnnouncementKey) K(NSAccessibilityAnnouncementRequestedNotification) K(NSAccessibilityButtonRole)
K(NSAccessibilityCheckBoxRole) K(NSAccessibilityComboBoxRole) K(NSAccessibilityImageRole) K(NSAccessibilityLayoutAreaRole)
K(NSAccessibilityLinkRole) K(NSAccessibilityPriorityKey) K(NSAccessibilitySecureTextFieldSubrole) K(NSAccessibilitySliderRole)
K(NSAccessibilityStaticTextRole) K(NSAccessibilityTextFieldRole) K(NSAccessibilityTextLinkSubrole)
K(NSAccessibilityUIElementDestroyedNotification) K(NSAccessibilityUnknownRole) K(NSAccessibilityValueChangedNotification)
K(NSAccessibilityWindowRole) KV(NSCalibratedRGBColorSpace) K(NSPasteboardTypeFileURL) K(NSPasteboardTypeString) K(NSPasteboardTypeURL) K(NSDeviceSize)
K(NSPasteboardURLReadingFileURLsOnlyKey)
KV(NSViewBoundsDidChangeNotification) KV(NSViewFrameDidChangeNotification) K(NSWindowDidEndLiveResizeNotification)
K(NSWindowDidEnterFullScreenNotification) K(NSWindowDidExitFullScreenNotification) KV(NSWindowDidMoveNotification)
KV(NSWindowWillMoveNotification) K(NSWindowWillStartLiveResizeNotification) K(NSWorkspaceActiveSpaceDidChangeNotification)
KV(NSWorkspaceSessionDidBecomeActiveNotification) KV(NSWorkspaceSessionDidResignActiveNotification)
// SDL2's Cocoa backend and Hades II. ponytail: named only; the host posts none of these (one window, one screen,
// never minimized or closed from outside).
K(NSApplicationWillTerminateNotification) K(NSWindowDidBecomeMainNotification) K(NSWindowDidResignMainNotification)
K(NSWindowDidResignKeyNotification) K(NSWindowDidChangeScreenNotification) K(NSWindowDidChangeScreenProfileNotification)
K(NSWindowDidChangeBackingPropertiesNotification) K(NSWindowDidMiniaturizeNotification) K(NSWindowDidDeminiaturizeNotification)
K(NSWindowDidExposeNotification) K(NSWindowWillEnterFullScreenNotification) K(NSWindowWillExitFullScreenNotification)
K(NSWorkspaceDidActivateApplicationNotification) K(NSWorkspaceDidDeactivateApplicationNotification)
K(NSBackingPropertyOldScaleFactorKey) K(NSDeviceRGBColorSpace) KV(NSFilenamesPboardType)
K(NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification)   // Godot 4; never posted
K(NSWorkspaceLaunchConfigurationAppleEvent) K(NSWorkspaceLaunchConfigurationArchitecture)   // Unity 5 player
K(NSWorkspaceLaunchConfigurationArguments) K(NSWorkspaceLaunchConfigurationEnvironment)
K(NSAppearanceNameAqua) K(NSAppearanceNameDarkAqua)   // CoronaCards; NSAppearance answers nil (light), see Stubs.m
K(NSWorkspaceWillSleepNotification) K(NSWorkspaceDidWakeNotification)   // Crimson Desert; never posted
K(NSImageHintInterpolation)   // Cyberpunk 2077
KV(NSDeviceResolution)   // GameMaker's runner (TetherGeist); see -[NSScreen deviceDescription]
// ponytail: the pre-10.14 name for the string type, given the same value so NSPasteboard.m treats it as one (GameMaker).
NSString *NSStringPboardType = @"NSPasteboardTypeString";
#undef K
#undef KV

const CGFloat NSFontWeightMedium = 0.23f;   // macOS value (a float widened); UIFont takes the same weights

// Values verified against AppKit on macOS; Unity 6 uses these for accessibility metadata.
NSString *const NSAccessibilityGroupRole = @"AXGroup";
NSString *const NSPasteboardTypePNG = @"public.png";   // Godot 4 clipboard images; the pasteboard shim holds strings only
NSString *const NSPasteboardTypeTIFF = @"public.tiff";
NSString *const NSAccessibilityLayoutChangedNotification = @"AXLayoutChanged";
NSString *const NSAccessibilityPopUpButtonRole = @"AXPopUpButton";
NSString *const NSAccessibilityRadioButtonRole = @"AXRadioButton";
NSString *const NSAccessibilityScrollAreaRole = @"AXScrollArea";
NSString *const NSAccessibilitySearchFieldSubrole = @"AXSearchField";
NSString *const NSAccessibilityTabButtonSubrole = @"AXTabButton";
NSString *const NSAccessibilityTabGroupRole = @"AXTabGroup";
NSString *const NSAccessibilityUIElementsKey = @"AXUIElementsKey";
NSString *const NSAccessibilityUnknownSubrole = @"AXUnknown";
// Godot 4.5 (AccessKit), values from macOS AppKit.
NSString *const NSAccessibilityCellRole = @"AXCell";
NSString *const NSAccessibilityColorWellRole = @"AXColorWell";
NSString *const NSAccessibilityDialogSubrole = @"AXDialog";
NSString *const NSAccessibilityFocusedUIElementChangedNotification = @"AXFocusedUIElementChanged";
NSString *const NSAccessibilityIncrementorRole = @"AXIncrementor";
NSString *const NSAccessibilityLevelIndicatorRole = @"AXLevelIndicator";
NSString *const NSAccessibilityListRole = @"AXList";
NSString *const NSAccessibilityMenuBarRole = @"AXMenuBar";
NSString *const NSAccessibilityMenuItemRole = @"AXMenuItem";
NSString *const NSAccessibilityMenuRole = @"AXMenu";
NSString *const NSAccessibilityOutlineRole = @"AXOutline";
NSString *const NSAccessibilityOutlineRowSubrole = @"AXOutlineRow";
NSString *const NSAccessibilityProgressIndicatorRole = @"AXProgressIndicator";
NSString *const NSAccessibilityRadioGroupRole = @"AXRadioGroup";
NSString *const NSAccessibilityRowRole = @"AXRow";
NSString *const NSAccessibilityScrollBarRole = @"AXScrollBar";
NSString *const NSAccessibilitySelectedRowsChangedNotification = @"AXSelectedRowsChanged";
NSString *const NSAccessibilitySelectedTextChangedNotification = @"AXSelectedTextChanged";
NSString *const NSAccessibilitySplitterRole = @"AXSplitter";
NSString *const NSAccessibilitySwitchSubrole = @"AXSwitch";
NSString *const NSAccessibilityTableRole = @"AXTable";
NSString *const NSAccessibilityTableRowSubrole = @"AXTableRow";
NSString *const NSAccessibilityTextAreaRole = @"AXTextArea";
NSString *const NSAccessibilityTitleChangedNotification = @"AXTitleChanged";
NSString *const NSAccessibilityToggleSubrole = @"AXToggle";
NSString *const NSAccessibilityToolbarRole = @"AXToolbar";

// ponytail: no macOS accessibility server on iOS; posts go nowhere.
NSString *NSAccessibilityRoleDescription(NSString *role, NSString *subrole) { return role; }
void NSAccessibilityPostNotification(id element, NSString *notification) {}
void NSAccessibilityPostNotificationWithUserInfo(id element, NSString *notification, NSDictionary *userInfo) {}

#define ALERT_PANEL(name) \
NSInteger name(NSString *title, NSString *msgFormat, NSString *defaultButton, NSString *alternateButton, NSString *otherButton, ...) { \
    va_list ap; va_start(ap, otherButton); \
    NSString *msg = msgFormat ? [[NSString alloc] initWithFormat:msgFormat arguments:ap] : @""; \
    va_end(ap); \
    NSLog(@"[ShackAppKit] " #name ": %@ — %@", title, msg); \
    return 1;   /* NSAlertDefaultReturn; ponytail: logged, not shown */ \
}
ALERT_PANEL(NSRunInformationalAlertPanel)
ALERT_PANEL(NSRunAlertPanel)
