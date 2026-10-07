#import "ShackAppKit.h"
@class NSImage;
// ponytail: one shared cursor object for every system cursor; iOS draws its own pointer, so set/push/pop/hide do nothing.
@interface NSCursor : NSObject
- (instancetype)initWithImage:(NSImage *)image hotSpot:(NSPoint)hotSpot;
@property (nonatomic, readonly, strong) NSImage *image; @property (nonatomic, readonly) NSPoint hotSpot;
@end
@implementation NSCursor
SHACK_SAFETY_NET
+ (NSCursor *)shared { static NSCursor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [self new]; }); return c; }
#define SYS(n) + (NSCursor *)n { return [NSCursor shared]; }
SYS(arrowCursor) SYS(IBeamCursor) SYS(crosshairCursor) SYS(closedHandCursor) SYS(openHandCursor) SYS(pointingHandCursor)
SYS(resizeLeftRightCursor) SYS(resizeUpDownCursor) SYS(operationNotAllowedCursor) SYS(currentCursor)
#undef SYS
+ (void)hide {} + (void)unhide {} + (void)setHiddenUntilMouseMoves:(BOOL)f {}
- (instancetype)initWithImage:(NSImage *)image hotSpot:(NSPoint)hotSpot { if ((self = [super init])) { _image = image; _hotSpot = hotSpot; } return self; }
- (void)set {} - (void)push {} - (void)pop {}
@end
