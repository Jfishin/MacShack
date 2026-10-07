#import "ShackAppKit.h"
#import <dlfcn.h>
#import "../ShackDisplay.h"
// UIScreen.mainScreen is deprecated since iOS 26; the host has exactly one scene.
static UIScreen *ShackUIScreen(void) { return ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).screen; }

// macOS NSGeometry spellings of NSValue (iOS has only the CG ones): Godot reads deviceDescription[NSDeviceSize].sizeValue.
@implementation NSValue (ShackGeometry)
+ (NSValue *)valueWithSize:(NSSize)s { return [NSValue valueWithCGSize:s]; }
+ (NSValue *)valueWithPoint:(NSPoint)p { return [NSValue valueWithCGPoint:p]; }
+ (NSValue *)valueWithRect:(NSRect)r { return [NSValue valueWithCGRect:r]; }
- (NSSize)sizeValue { return self.CGSizeValue; }
- (NSPoint)pointValue { return self.CGPointValue; }
- (NSRect)rectValue { return self.CGRectValue; }
@end

@implementation NSScreen { CGRect _frame; CGFloat _scale, _native; NSInteger _fps; BOOL _ready; }
SHACK_SAFETY_NET
// ponytail: metrics captured once; rotation/screen changes are not tracked. Games read these per frame off-main,
// so a per-call ShackMainSync would deadlock against any main-thread wait on a render thread. The loader primes
// this on the main thread before the guest starts; ShackMainSync stays outside dispatch_once so a racing
// off-main first call cannot deadlock, and a scale of 0 (no scene yet) is retried, not cached.
+ (NSScreen *)mainScreen {
    static NSScreen *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSScreen new]; });
    if (!s->_ready) ShackMainSync(^{
        if (s->_ready) return;
        UIScreen *u = ShackUIScreen(); CGSize b = u.bounds.size; s->_frame = CGRectMake(0, 0, MAX(b.width, b.height), MIN(b.width, b.height));   // ponytail: games are landscape-only
        s->_scale = s->_native = u.nativeScale; s->_fps = u.maximumFramesPerSecond; s->_ready = s->_scale > 0;
        const char *e = getenv("SHACK_RENDER_SCALE");   // the loader's per-game render scale; only ever lowers it
        if (e && atof(e) > 0 && atof(e) < s->_scale) s->_scale = atof(e);
        CGSize virtualSize;
        if (ShackVirtualDisplaySize(&virtualSize)) {
            s->_frame = (CGRect){CGPointZero, virtualSize}; s->_scale = 1; s->_ready = YES;
            NSLog(@"[ShackAppKit] virtual display %.0fx%.0f, backing scale 1", virtualSize.width, virtualSize.height);
        }
    });
    return s;
}
+ (NSArray<NSScreen *> *)screens { return @[self.mainScreen]; }
- (NSRect)frame { return _frame; }   // points, origin 0,0 either convention
- (NSRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return _scale; }
// Unity sizes its Metal drawable from convertRectToBacking: of the screen frame (0x0 without it -> "could not switch
// resolutions", exit 1) and reads safeAreaInsets for Screen.safeArea. Struct returns must be real, not forwarded.
- (NSRect)convertRectToBacking:(NSRect)r { return NSMakeRect(r.origin.x * _scale, r.origin.y * _scale, r.size.width * _scale, r.size.height * _scale); }
- (NSRect)convertRectFromBacking:(NSRect)r { return NSMakeRect(r.origin.x / _scale, r.origin.y / _scale, r.size.width / _scale, r.size.height / _scale); }
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsZero; }   /* NSEdgeInsets and UIEdgeInsets share {top,left,bottom,right} */   // ponytail: full-bleed; wire UIWindow.safeAreaInsets if HUD elements hide under the island
+ (BOOL)screensHaveSeparateSpaces { return NO; }
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue { return 1; }   // ponytail: SDR until EDR output is wired up
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue { return 1; }
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 0; }
// The display the game sees: libShackCV's rate (the frame cap when capped), as CGDisplayModeGetRefreshRate reports it.
- (NSInteger)maximumFramesPerSecond {
    static double (*cv)(void); static dispatch_once_t once;
    dispatch_once(&once, ^{ cv = (double (*)(void))dlsym(RTLD_DEFAULT, "ShackCVRefreshRate"); });
    return cv ? lround(cv()) : _fps;
}
- (NSString *)localizedName { return @"iPhone"; }
- (id)colorSpace { return nil; }
// The keys macOS gives; GameMaker reads NSDeviceResolution (72 dpi per backing pixel) for display_get_dpi_x/y.
- (NSDictionary *)deviceDescription {
    return @{@"NSScreenNumber": @1, @"NSDeviceSize": [NSValue valueWithCGSize:self.frame.size],
             @"NSDeviceResolution": [NSValue valueWithCGSize:CGSizeMake(72 * _scale, 72 * _scale)], @"NSDeviceIsScreen": @"YES",
             @"NSDeviceBitsPerSample": @8, @"NSDeviceColorSpaceName": @"NSCalibratedRGBColorSpace"};
}
// The render scale for what starts next (the Steam client's UI, then a game it starts in this process; the host sets it
// back when the game ends): the backing scale every window and view reports from now on. 0 = the panel's own; never
// above it. ponytail: no backing-change notifications, so a running guest keeps the scale it started with (layers
// already attached keep their contentsScale).
- (void)shack_setRenderScale:(CGFloat)scale {
    if (!_ready || ShackVirtualDisplaySize(NULL)) return;
    _scale = scale > 0 && scale < _native ? scale : _native;
}
@end
void ShackAppKitSetRenderScale(double scale) { [NSScreen.mainScreen shack_setRenderScale:scale]; }
