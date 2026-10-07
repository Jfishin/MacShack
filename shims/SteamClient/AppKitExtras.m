// libShackSteamClient: Objective-C answers the macOS Steam client needs from MacShack's AppKit shim. Loaded only with the
// Steam client, so these categories never reach a game. NSFont and NSColor are the shim's UIFont/UIColor subclasses,
// the only shim classes without its unknown-selector safety net (the others inherit it from NSResponder): they get it
// here, plus real answers for what Steam's own windows ask first (steam_osx's bootstrapper: +[NSFont labelFontOfSize:]).
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

NSMethodSignature *ShackStubSignature(SEL sel);   // libShackAppKit, ShackSafetyNet.m
void ShackStubInvoke(id self, NSInvocation *inv);
#define STEAM_SAFETY_NET \
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \
- (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); } \
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: ShackStubSignature(s); } \
+ (void)forwardInvocation:(NSInvocation *)i { ShackStubInvoke(self, i); }

@interface NSFont : UIFont @end
@implementation NSFont (SteamClient)
STEAM_SAFETY_NET
+ (UIFont *)labelFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size ?: 10]; }
+ (UIFont *)messageFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size ?: 13]; }
+ (UIFont *)menuFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size ?: 13]; }
+ (UIFont *)controlContentFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size ?: 13]; }
+ (UIFont *)titleBarFontOfSize:(CGFloat)size { return [UIFont boldSystemFontOfSize:size ?: 13]; }
+ (UIFont *)userFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size ?: 13]; }
+ (UIFont *)userFixedPitchFontOfSize:(CGFloat)size { return [UIFont monospacedSystemFontOfSize:size ?: 13 weight:UIFontWeightRegular]; }
+ (CGFloat)systemFontSizeForControlSize:(NSUInteger)controlSize { return controlSize == 1 ? 11 : controlSize == 2 ? 9 : 13; }
+ (CGFloat)smallSystemFontSize { return 11; }
+ (CGFloat)labelFontSize { return 10; }
@end

// macOS's semantic colours as their iOS counterparts (macOS's default accent is blue).
@interface NSColor : UIColor @end
@implementation NSColor (SteamClient)
STEAM_SAFETY_NET
+ (UIColor *)controlTextColor { return UIColor.labelColor; }
+ (UIColor *)disabledControlTextColor { return UIColor.tertiaryLabelColor; }
+ (UIColor *)alternateSelectedControlTextColor { return UIColor.whiteColor; }
+ (UIColor *)selectedTextBackgroundColor { return [UIColor.systemBlueColor colorWithAlphaComponent:0.3]; }
+ (UIColor *)unemphasizedSelectedContentBackgroundColor { return UIColor.systemGray5Color; }
+ (UIColor *)keyboardFocusIndicatorColor { return [UIColor.systemBlueColor colorWithAlphaComponent:0.5]; }
+ (NSArray<UIColor *> *)alternatingContentBackgroundColors { return @[UIColor.systemBackgroundColor, UIColor.secondarySystemBackgroundColor]; }
+ (NSUInteger)currentControlTint { return 1; }   // NSBlueControlTint
+ (UIColor *)colorWithCatalogName:(NSString *)list colorName:(NSString *)name { return UIColor.labelColor; }
+ (UIColor *)colorWithColorSpace:(id)space components:(const CGFloat *)c count:(NSInteger)n {
    return n >= 4 ? [UIColor colorWithRed:c[0] green:c[1] blue:c[2] alpha:c[3]] : n >= 2 ? [UIColor colorWithWhite:c[0] alpha:c[1]] : UIColor.blackColor;
}
@end

// Chromium's font matching (Blink's MatchNSFontFamily, last-resort Times/Lucida Grande) walks NSFontManager's families and
// their members; with none it has no fallback font and crashes on a NULL one (the sign-in window's first web font).
// The iOS fonts, described as AppKit does: CoreText's symbolic traits share NSFontTraitMask's bits (italic 0x1, bold
// 0x2, expanded 0x20, condensed 0x40, fixed pitch 0x400); weights on AppKit's 0-15 scale.
@interface NSFontManager : NSObject @end
static int appKitWeight(UIFont *font) {
    NSDictionary *traits = CFBridgingRelease(CTFontCopyTraits((__bridge CTFontRef)font));
    double w = [traits[(__bridge NSString *)kCTFontWeightTrait] doubleValue];
    return w < -0.7 ? 2 : w < -0.5 ? 3 : w < -0.2 ? 4 : w < 0.1 ? 5 : w < 0.27 ? 6 : w < 0.35 ? 8 : w < 0.5 ? 9 : w < 0.6 ? 10 : 12;
}
static NSUInteger appKitTraits(UIFont *font) { return font ? CTFontGetSymbolicTraits((__bridge CTFontRef)font) & 0x463 : 0; }
@implementation NSFontManager (SteamClient)
+ (instancetype)sharedFontManager {
    static NSFontManager *shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (NSArray<NSString *> *)availableFontFamilies { return UIFont.familyNames; }
- (NSArray<NSString *> *)availableFonts {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *family in UIFont.familyNames) [names addObjectsFromArray:[UIFont fontNamesForFamilyName:family]];
    return names;
}
// Each member: @[PostScript name, style name, weight, traits].
- (NSArray<NSArray *> *)availableMembersOfFontFamily:(NSString *)family {
    NSMutableArray *members = [NSMutableArray array];
    for (NSString *name in family ? [UIFont fontNamesForFamilyName:family] : @[]) {
        UIFont *font = [UIFont fontWithName:name size:12];
        if (!font) continue;
        NSString *style = CFBridgingRelease(CTFontCopyName((__bridge CTFontRef)font, kCTFontStyleNameKey)) ?: @"Regular";
        [members addObject:@[name, style, @(appKitWeight(font)), @(appKitTraits(font))]];
    }
    return members;
}
- (NSInteger)weightOfFont:(UIFont *)font { return font ? appKitWeight(font) : 5; }
- (NSUInteger)traitsOfFont:(UIFont *)font { return appKitTraits(font); }
- (UIFont *)convertFont:(UIFont *)font toHaveTrait:(NSUInteger)trait {
    if (!font) return nil;
    CTFontRef converted = CTFontCreateCopyWithSymbolicTraits((__bridge CTFontRef)font, 0, NULL, (CTFontSymbolicTraits)(trait & 0x463), (CTFontSymbolicTraits)(trait & 0x463));
    return converted ? CFBridgingRelease(converted) : font;
}
- (UIFont *)convertFont:(UIFont *)font toNotHaveTrait:(NSUInteger)trait {
    if (!font) return nil;
    CTFontRef converted = CTFontCreateCopyWithSymbolicTraits((__bridge CTFontRef)font, 0, NULL, 0, (CTFontSymbolicTraits)(trait & 0x463));
    return converted ? CFBridgingRelease(converted) : font;
}
- (UIFont *)convertWeight:(BOOL)heavier ofFont:(UIFont *)font { return font; }
// The family member closest to weight with every wanted trait.
- (UIFont *)fontWithFamily:(NSString *)family traits:(NSUInteger)traits weight:(NSInteger)weight size:(CGFloat)size {
    NSString *best = nil; NSInteger bestDistance = NSIntegerMax;
    for (NSArray *m in [self availableMembersOfFontFamily:family]) {
        if (([m[3] unsignedIntegerValue] & traits & 0x463) != (traits & 0x463)) continue;
        NSInteger d = labs([m[2] integerValue] - weight);
        if (d < bestDistance) { bestDistance = d; best = m[0]; }
    }
    return best ? [UIFont fontWithName:best size:size] : nil;
}
@end

// Steam starts an app-bundle game through -[NSWorkspace launchApplicationAtURL:options:configuration:error:]: MacShack's
// host adds it (host/ShackSteamClient.m) and runs the game in-process.

// No nib loading for Steam's windows (it draws its UI with Chromium): a nib that is not there.
@implementation NSBundle (SteamClient)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray **)objects { if (objects) *objects = nil; return NO; }
+ (BOOL)loadNibNamed:(NSString *)name owner:(id)owner { return NO; }
@end

// Steam Input asks whether GameController drives a HID device itself; on iOS the pads reach Steam through the IOKit
// shim's virtual HID devices.
@implementation GCController (SteamClient)
+ (BOOL)supportsHIDDevice:(id)device { return NO; }
@end
