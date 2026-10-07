#import "ShackAppKit.h"
#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>

@interface NSWorkspace : NSObject
+ (NSWorkspace *)sharedWorkspace;
@property (nonatomic, readonly) NSNotificationCenter *notificationCenter; @property (nonatomic, readonly) NSArray *runningApplications;
@property (nonatomic, readonly) id frontmostApplication;
- (BOOL)openURL:(NSURL *)url; - (BOOL)openFile:(NSString *)path; - (BOOL)selectFile:(NSString *)path inFileViewerRootedAtPath:(NSString *)root;
@end
@implementation NSWorkspace
SHACK_SAFETY_NET
+ (NSWorkspace *)sharedWorkspace { static NSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [self new]; }); return w; }
- (NSNotificationCenter *)notificationCenter { return NSNotificationCenter.defaultCenter; }   // ponytail: workspace notifications never fire on iOS
- (NSArray *)runningApplications { return @[]; }
- (id)frontmostApplication { return nil; }
- (BOOL)openURL:(NSURL *)url { ShackMainSync(^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; }); return YES; }
- (BOOL)openFile:(NSString *)path { return NO; }
- (BOOL)selectFile:(NSString *)path inFileViewerRootedAtPath:(NSString *)root { return NO; }
- (NSString *)fullPathForApplication:(NSString *)app { return nil; }   // no other apps on iOS; UE4 then reports ENOENT
- (BOOL)isFilePackageAtPath:(NSString *)p { return [p.pathExtension isEqualToString:@"app"]; }
@end

// Options for opening apps/URLs (Godot 3 builds one); no other apps to open on iOS, so it only holds values.
@interface NSWorkspaceOpenConfiguration : NSObject @end
@implementation NSWorkspaceOpenConfiguration
SHACK_SAFETY_NET
+ (instancetype)configuration { return [self new]; }
@end

// ponytail: no Apple events on iOS; handlers are accepted and never called.
@interface NSAppleEventManager : NSObject
+ (NSAppleEventManager *)sharedAppleEventManager;
- (void)setEventHandler:(id)handler andSelector:(SEL)sel forEventClass:(FourCharCode)eventClass andEventID:(FourCharCode)eventID;
@end
@implementation NSAppleEventManager
SHACK_SAFETY_NET
+ (NSAppleEventManager *)sharedAppleEventManager { static NSAppleEventManager *m; static dispatch_once_t o; dispatch_once(&o, ^{ m = [self new]; }); return m; }
- (void)setEventHandler:(id)handler andSelector:(SEL)sel forEventClass:(FourCharCode)eventClass andEventID:(FourCharCode)eventID {}
@end

@interface NSColorSpace : NSObject + (instancetype)sRGBColorSpace; @end   // Stubs.m
@interface NSBitmapImageRep : NSObject
+ (instancetype)imageRepWithData:(NSData *)data;
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bps
    samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar colorSpaceName:(NSString *)colorSpaceName bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits;
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bps
    samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar colorSpaceName:(NSString *)colorSpaceName bitmapFormat:(NSUInteger)bitmapFormat
    bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits;
@property (nonatomic, readonly) unsigned char *bitmapData; @property (nonatomic, readonly) NSInteger pixelsWide, pixelsHigh, bytesPerRow;
@property (nonatomic, readonly) NSInteger bitsPerPixel, bitsPerSample, samplesPerPixel; @property (nonatomic, readonly) BOOL hasAlpha;
@property (nonatomic, readonly) id colorSpace;
- (NSData *)representationUsingType:(NSUInteger)type properties:(NSDictionary *)properties; - (NSData *)TIFFRepresentation;
@end
@implementation NSBitmapImageRep { BOOL _owns; }
SHACK_SAFETY_NET
+ (instancetype)imageRepWithData:(NSData *)data { return [[self alloc] initWithData:data]; }
// Decoded with ImageIO into what macOS hands back for a PNG, which Factorio's loader relies on: 8-bit sRGB, alpha last
// and not premultiplied, rows packed tight. ponytail: grey and 16-bit sources come back as 8-bit RGB(A) too.
- (instancetype)initWithData:(NSData *)data {
    CGImageSourceRef src = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!image) { NSLog(@"[ShackAppKit] NSBitmapImageRep: ImageIO cannot decode %lu bytes", (unsigned long)data.length); return nil; }
    if (!(self = [super init])) { CGImageRelease(image); return nil; }
    CGImageAlphaInfo a = CGImageGetAlphaInfo(image);
    _hasAlpha = a != kCGImageAlphaNone && a != kCGImageAlphaNoneSkipLast && a != kCGImageAlphaNoneSkipFirst;
    _samplesPerPixel = _hasAlpha ? 4 : 3; _bitsPerSample = 8; _bitsPerPixel = _samplesPerPixel * 8;
    _pixelsWide = (NSInteger)CGImageGetWidth(image); _pixelsHigh = (NSInteger)CGImageGetHeight(image);
    _bytesPerRow = _pixelsWide * _samplesPerPixel;
    _bitmapData = malloc((size_t)(_bytesPerRow * _pixelsHigh)); _owns = YES;
    _colorSpace = NSColorSpace.sRGBColorSpace;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    vImage_CGImageFormat format = {.bitsPerComponent = 8, .bitsPerPixel = (uint32_t)_bitsPerPixel, .colorSpace = srgb,
                                   .bitmapInfo = (CGBitmapInfo)(_hasAlpha ? kCGImageAlphaLast : kCGImageAlphaNone)};
    vImage_Buffer buf = {_bitmapData, (vImagePixelCount)_pixelsHigh, (vImagePixelCount)_pixelsWide, (size_t)_bytesPerRow};
    vImage_Error e = _bitmapData ? vImageBuffer_InitWithCGImage(&buf, &format, NULL, image, kvImageNoAllocate) : kvImageMemoryAllocationError;
    CGColorSpaceRelease(srgb); CGImageRelease(image);
    if (e != kvImageNoError) NSLog(@"[ShackAppKit] NSBitmapImageRep: vImage error %ld", (long)e);
    return e == kvImageNoError ? self : nil;
}
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bps
    samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar colorSpaceName:(NSString *)colorSpaceName bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits {
    return [self initWithBitmapDataPlanes:planes pixelsWide:width pixelsHigh:height bitsPerSample:bps samplesPerPixel:spp hasAlpha:alpha isPlanar:isPlanar
                           colorSpaceName:colorSpaceName bitmapFormat:0 bytesPerRow:rBytes bitsPerPixel:pBits];
}
// ponytail: meshed (non-planar) layout only; planar callers get one plane.
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bps
    samplesPerPixel:(NSInteger)spp hasAlpha:(BOOL)alpha isPlanar:(BOOL)isPlanar colorSpaceName:(NSString *)colorSpaceName bitmapFormat:(NSUInteger)bitmapFormat
    bytesPerRow:(NSInteger)rBytes bitsPerPixel:(NSInteger)pBits {
    if (!(self = [super init])) return nil;
    if (!pBits) pBits = bps * spp;
    _pixelsWide = width; _pixelsHigh = height; _bytesPerRow = rBytes ?: (width * pBits + 7) / 8;
    _bitsPerPixel = pBits; _bitsPerSample = bps; _samplesPerPixel = spp; _hasAlpha = alpha;
    if (planes && planes[0]) _bitmapData = planes[0];   // caller owns the buffer, as on macOS
    else { _bitmapData = calloc((size_t)(_bytesPerRow * height), 1); _owns = YES; if (!_bitmapData) return nil; }
    return self;
}
- (void)dealloc { if (_owns) free(_bitmapData); }
- (NSData *)representationUsingType:(NSUInteger)type properties:(NSDictionary *)properties { return nil; }
- (NSData *)TIFFRepresentation { return nil; }
@end

// ponytail: UE4's log console window; nothing is displayed, text is kept so reads round-trip.
@interface NSScrollView : NSView
@property (nonatomic, strong) NSView *documentView; @property (nonatomic) BOOL hasHorizontalScroller, hasVerticalScroller;
@end
@implementation NSScrollView
- (NSSize)contentSize { return self.frame.size; }   // no scrollers drawn: content == frame
- (NSRect)documentVisibleRect { return (NSRect){CGPointZero, self.frame.size}; }
@end

@interface NSTextView : NSView
@property (nonatomic, copy) NSString *string; @property (nonatomic, weak) id delegate; @property (nonatomic, getter=isEditable) BOOL editable;
@property (nonatomic, getter=isSelectable) BOOL selectable; @property (nonatomic, readonly) id textStorage;
@property (nonatomic) NSSize minSize, maxSize;
- (void)insertText:(id)text; - (void)insertText:(id)text replacementRange:(NSRange)range; - (void)scrollRangeToVisible:(NSRange)range;
@end
@implementation NSTextView
- (id)textContainer { return nil; }   // ponytail: no NSTextContainer; sends to nil are no-ops
- (id)textStorage { return nil; }   // ponytail: no NSTextStorage; appends through it are dropped
- (void)insertText:(id)text { [self insertText:text replacementRange:NSMakeRange(NSNotFound, 0)]; }
- (void)insertText:(id)text replacementRange:(NSRange)range {
    NSString *s = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
    self.string = [(self.string ?: @"") stringByAppendingString:s ?: @""];
}
- (void)scrollRangeToVisible:(NSRange)range {}
@end
