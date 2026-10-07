#import "ShackAppKit.h"

@interface NSColor : UIColor @end
// macOS semantic colours (Godot 4 reads these at window creation) as their iOS counterparts; macOS's default accent is blue.
@implementation NSColor
+ (UIColor *)windowBackgroundColor { return UIColor.systemBackgroundColor; }
+ (UIColor *)controlColor { return UIColor.secondarySystemBackgroundColor; }
+ (UIColor *)controlAccentColor { return UIColor.systemBlueColor; }
@end
@interface NSFont : UIFont @end
@implementation NSFont @end
// ponytail: images are only used for cursors and icons, which iOS never shows; they stay empty.
@interface NSImage : UIImage
- (instancetype)initWithSize:(NSSize)size; - (void)addRepresentation:(id)rep; - (void)setSize:(NSSize)size;
@end
@implementation NSImage
SHACK_SAFETY_NET
- (instancetype)initWithSize:(NSSize)size { return [self init]; }
- (void)addRepresentation:(id)rep {}
- (void)setSize:(NSSize)size {}
- (void)lockFocus {} - (void)unlockFocus {}
- (NSArray *)representations { return @[]; }
@end

@interface UIColor (ShackAppKit)
+ (UIColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (UIColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (UIColor *)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
- (UIColor *)colorUsingColorSpace:(id)space;
- (CGFloat)redComponent; - (CGFloat)greenComponent; - (CGFloat)blueComponent; - (CGFloat)alphaComponent;
@end
@implementation UIColor (ShackAppKit)
+ (UIColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self colorWithRed:r green:g blue:b alpha:a]; }
+ (UIColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self colorWithRed:r green:g blue:b alpha:a]; }
+ (UIColor *)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self colorWithRed:r green:g blue:b alpha:a]; }
- (UIColor *)colorUsingColorSpace:(id)space { return self; }   // ponytail: components already read as sRGB
- (CGFloat)redComponent { CGFloat r; [self getRed:&r green:NULL blue:NULL alpha:NULL]; return r; }
- (CGFloat)greenComponent { CGFloat g; [self getRed:NULL green:&g blue:NULL alpha:NULL]; return g; }
- (CGFloat)blueComponent { CGFloat b; [self getRed:NULL green:NULL blue:&b alpha:NULL]; return b; }
- (CGFloat)alphaComponent { CGFloat a; [self getRed:NULL green:NULL blue:NULL alpha:&a]; return a; }
@end
