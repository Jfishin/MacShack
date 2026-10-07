// The application delegate named by a main nib, in either compiled format: the keyed-archive plist older Xcode wrote
// (Unity players) or the binary "NIBArchive" newer Xcode writes (Hades II). Only the delegate outlet is read.
//
// NIBArchive layout (reverse-engineered, stable since 10.x): "NIBArchive", two uint32 (format, coder version), then
// four (count, offset) uint32 pairs for objects, keys, values, class names. Varints are little-endian 7-bit groups with
// the high bit marking the LAST byte. object = class index, first value index, value count; key = varint length + bytes;
// value = key index, type byte, payload (0 int8, 1 int16, 2 int32, 3 int64, 4 true, 5 false, 6 float, 7 double,
// 8 varint length + bytes, 9 nil, 10 uint32 object index); class name = varint length, varint extra count, extra
// int32s, bytes (NUL included).
#ifdef SHACK_NIB_TEST   // the Mac check reads real nibs with Foundation alone
#import <Foundation/Foundation.h>
#else
#import "ShackAppKit.h"
#endif

static uint64_t Varint(const uint8_t **p, const uint8_t *end) {
    uint64_t v = 0; int shift = 0;
    while (*p < end) { uint8_t b = *(*p)++; v |= (uint64_t)(b & 0x7f) << shift; if (b & 0x80) break; shift += 7; }
    return v;
}

typedef struct { uint32_t cls, first, count; } NibObj;
typedef struct { uint32_t key; uint8_t type; uint64_t ref; int64_t num; double dbl; NSData *bytes; } NibVal;

// A parsed NIBArchive: objects with their key/value lists (values are read by key on demand).
@interface ShackNibArchive : NSObject {
    NibObj *_objs; NibVal *_vals; uint32_t _nObj, _nVal;
    NSMutableArray<NSString *> *_keys, *_classes;
    NSMutableDictionary<NSNumber *, id> *_instances;
}
+ (instancetype)parse:(NSData *)data;
@property (readonly) uint32_t objectCount;
- (NSString *)classOf:(uint32_t)o;
- (NibVal *)value:(uint32_t)o key:(NSString *)k;
- (NSString *)stringAt:(uint32_t)o;                          // an NSString / NSLocalizableString object: its NS.bytes
- (NSString *)stringValue:(uint32_t)o key:(NSString *)k;      // the string a key refers to
- (NSString *)nameOf:(uint32_t)o;                            // NSCustomObject / NSClassSwapper -> its class name, else its archived class
- (NSArray<NSNumber *> *)members:(uint32_t)o;                // an archived NSArray / NSSet: the objects it holds
#ifndef SHACK_NIB_TEST
- (void)connectDelegate:(id)delegate name:(NSString *)delegateName;
#endif
@end
#ifndef SHACK_NIB_TEST
static NSMutableArray *gLaunchWindows;
// The main nib's objects live as long as the app, as AppKit keeps them: outlets are often assign (GameMaker's window).
static ShackNibArchive *gMainNib;
NSArray *ShackNibLaunchWindows(void) { return gLaunchWindows ?: @[]; }
#endif

@implementation ShackNibArchive
+ (instancetype)parse:(NSData *)data {
    const uint8_t *base = data.bytes, *end = base + data.length;
    if (data.length < 50 || memcmp(base, "NIBArchive", 10)) return nil;
    uint32_t h[10]; memcpy(h, base + 10, sizeof h);   // format, version, then (count, offset) x 4, little-endian
    uint32_t nObj = h[2], oObj = h[3], nKey = h[4], oKey = h[5], nVal = h[6], oVal = h[7], nCls = h[8], oCls = h[9];
    if (oObj > data.length || oKey > data.length || oVal > data.length || oCls > data.length) return nil;
    ShackNibArchive *a = [self new];
    a->_nObj = nObj; a->_nVal = nVal; a->_objs = calloc(nObj, sizeof *a->_objs); a->_vals = calloc(nVal, sizeof *a->_vals);
    a->_keys = [NSMutableArray array]; a->_classes = [NSMutableArray array]; a->_instances = [NSMutableDictionary dictionary];
    const uint8_t *p = base + oObj;
    for (uint32_t i = 0; i < nObj; i++) { a->_objs[i].cls = (uint32_t)Varint(&p, end); a->_objs[i].first = (uint32_t)Varint(&p, end); a->_objs[i].count = (uint32_t)Varint(&p, end); }
    p = base + oKey;
    for (uint32_t i = 0; i < nKey && p < end; i++) {
        uint64_t n = Varint(&p, end); if (p + n > end) break;
        [a->_keys addObject:[[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @""]; p += n;
    }
    p = base + oVal;
    static const int fixed[] = { 1, 2, 4, 8, 0, 0, 4, 8, -1, 0, 4 };
    for (uint32_t i = 0; i < nVal && p < end; i++) {
        NibVal *v = &a->_vals[i];
        v->key = (uint32_t)Varint(&p, end); v->type = p < end ? *p++ : 9;
        if (v->type == 8) { uint64_t n = Varint(&p, end); if (p + n > end) break; v->bytes = [NSData dataWithBytes:p length:n]; p += n; }
        else if (v->type <= 10) {
            int n = fixed[v->type]; if (p + n > end) break;
            switch (v->type) {
            case 0: v->num = (int8_t)p[0]; break;
            case 1: { int16_t x; memcpy(&x, p, 2); v->num = x; break; }
            case 2: { int32_t x; memcpy(&x, p, 4); v->num = x; break; }
            case 3: memcpy(&v->num, p, 8); break;
            case 4: v->num = 1; break;
            case 6: { float x; memcpy(&x, p, 4); v->dbl = x; break; }
            case 7: memcpy(&v->dbl, p, 8); break;
            case 10: memcpy(&v->ref, p, 4); break;
            }
            p += n;
        }
        else break;   // unknown type: the rest cannot be parsed
    }
    p = base + oCls;
    for (uint32_t i = 0; i < nCls && p < end; i++) {
        uint64_t n = Varint(&p, end), extra = Varint(&p, end); p += 4 * extra; if (p + n > end) break;
        [a->_classes addObject:[[NSString alloc] initWithBytes:p length:n ? n - 1 : 0 encoding:NSUTF8StringEncoding] ?: @""]; p += n;
    }
    return a;
}
- (void)dealloc { free(_objs); free(_vals); }
- (uint32_t)objectCount { return _nObj; }
- (NSString *)classOf:(uint32_t)o { return o < _nObj && _objs[o].cls < _classes.count ? _classes[_objs[o].cls] : nil; }
- (NibVal *)value:(uint32_t)o key:(NSString *)k {
    if (o >= _nObj) return NULL;
    for (uint32_t v = _objs[o].first; v < _objs[o].first + _objs[o].count && v < _nVal; v++)
        if (_vals[v].key < _keys.count && [_keys[_vals[v].key] isEqualToString:k]) return &_vals[v];
    return NULL;
}
- (NSString *)stringAt:(uint32_t)o {
    NibVal *b = [self value:o key:@"NS.bytes"];
    return b && b->bytes ? [[NSString alloc] initWithData:b->bytes encoding:NSUTF8StringEncoding] : nil;
}
- (NSString *)stringValue:(uint32_t)o key:(NSString *)k {
    NibVal *v = [self value:o key:k];
    return v && v->type == 10 ? [self stringAt:(uint32_t)v->ref] : nil;
}
- (NSString *)nameOf:(uint32_t)o {
    NibVal *n = [self value:o key:@"NSClassName"];
    return n && n->type == 10 ? [self stringAt:(uint32_t)n->ref] : [self classOf:o];
}
- (NSArray<NSNumber *> *)members:(uint32_t)o {
    NSMutableArray *m = [NSMutableArray array];
    for (uint32_t v = o < _nObj ? _objs[o].first : 0; o < _nObj && v < _objs[o].first + _objs[o].count && v < _nVal; v++)
        if (_vals[v].type == 10 && _vals[v].key < _keys.count && [_keys[_vals[v].key] isEqualToString:@"UINibEncoderEmptyKey"]) [m addObject:@(_vals[v].ref)];
    return m;
}
#ifndef SHACK_NIB_TEST
// The objects the connections tie together (a window, its content view): built from the archive's own description, wired to the
// delegate's outlets by key-value coding. Only what a main nib's window needs; menus and controls are not built.
- (id)instantiate:(uint32_t)o delegate:(id)delegate delegateName:(NSString *)delegateName {
    id cached = _instances[@(o)];
    if (cached) return cached == NSNull.null ? nil : cached;
    NSString *cls = [self classOf:o], *name = [self nameOf:o];
    id made = nil;
    if ([cls isEqualToString:@"NSCustomObject"] && [name isEqualToString:@"NSApplication"]) made = NSApp;
    else if (([cls isEqualToString:@"NSClassSwapper"] || [cls isEqualToString:@"NSCustomObject"]) && [name isEqualToString:delegateName]) made = delegate;
    else if ([cls isEqualToString:@"NSWindowTemplate"]) {
        NSString *rect = [self stringValue:o key:@"NSWindowRect"], *title = [self stringValue:o key:@"NSWindowTitle"];
        NSString *wcls = [self stringValue:o key:@"NSWindowClass"];
        Class c = NSClassFromString(wcls ?: @"NSWindow") ?: NSClassFromString(@"NSWindow");
        NibVal *style = [self value:o key:@"NSWindowStyleMask"], *backing = [self value:o key:@"NSWindowBacking"], *content = [self value:o key:@"NSWindowView"];
        NSRect frame = rect ? CGRectFromString(rect) : NSMakeRect(0, 0, 640, 480);
        // Typed sends, so ARC sees init's consumed self: an init that answers nil (NSPanel) already released it.
        made = [(NSWindow *)[c alloc] initWithContentRect:frame styleMask:(NSWindowStyleMask)(style ? style->num : 1)
                                                  backing:(NSBackingStoreType)(backing ? backing->num : 2) defer:NO];
        if (title.length && [made respondsToSelector:@selector(setTitle:)]) [made setTitle:title];
        _instances[@(o)] = made ?: NSNull.null;   // before the content view, which may refer back to it
        id view = content && content->type == 10 ? [self instantiate:(uint32_t)content->ref delegate:delegate delegateName:delegateName] : nil;
        if (view && [made respondsToSelector:@selector(setContentView:)]) [made setContentView:view];
        if (made && [self visibleAtLaunch:o]) { static dispatch_once_t once; dispatch_once(&once, ^{ gLaunchWindows = [NSMutableArray array]; }); [gLaunchWindows addObject:made]; }
        return made;
    } else if ([cls isEqualToString:@"NSClassSwapper"] || [cls isEqualToString:@"NSCustomView"] || [cls isEqualToString:@"NSView"] ||
               [cls hasPrefix:@"NS"] == NO) {   // a custom view (CoronaView, GameMaker's YYGLView) or a plain one holding it
        Class c = NSClassFromString(name);
        if (c && [c isSubclassOfClass:NSClassFromString(@"NSView")]) {
            NSString *size = [self stringValue:o key:@"NSFrameSize"], *frame = [self stringValue:o key:@"NSFrame"];
            NSRect r = frame ? CGRectFromString(frame) : NSMakeRect(0, 0, size ? CGSizeFromString(size).width : 320, size ? CGSizeFromString(size).height : 480);
            made = [(NSView *)[c alloc] initWithFrame:r];
            NibVal *flags = [self value:o key:@"NSvFlags"], *subs = [self value:o key:@"NSSubviews"];
            if (flags) [(NSView *)made setAutoresizingMask:(NSUInteger)flags->num & 0x3f];   // the low six bits are the resizing mask
            _instances[@(o)] = made ?: NSNull.null;   // before the subviews, which refer back to it
            for (NSNumber *sub in subs && subs->type == 10 ? [self members:(uint32_t)subs->ref] : @[]) {
                id v = [self instantiate:sub.unsignedIntValue delegate:delegate delegateName:delegateName];
                if (v) [(NSView *)made addSubview:v];
            }
        }
    }
    _instances[@(o)] = made ?: NSNull.null;
    return made;
}
// AppKit shows a nib's "Visible At Launch" windows (NSIBObjectData's NSVisibleWindows); the game orders the rest front.
- (BOOL)visibleAtLaunch:(uint32_t)window {
    for (uint32_t o = 0; o < _nObj; o++) {
        if (![[self classOf:o] isEqualToString:@"NSIBObjectData"]) continue;
        NibVal *set = [self value:o key:@"NSVisibleWindows"];
        return set && set->type == 10 && [[self members:(uint32_t)set->ref] containsObject:@(window)];
    }
    return NO;
}
// Every outlet connection whose two ends could be built: the delegate's `window`, the window's `delegate`, custom views.
- (void)connectDelegate:(id)delegate name:(NSString *)delegateName {
    NSMutableArray *built = [NSMutableArray array];
    for (uint32_t o = 0; o < _nObj; o++) {
        NSString *c = [self classOf:o];
        if (![c hasSuffix:@"OutletConnector"] && ![c isEqualToString:@"NSNibConnector"]) continue;
        NibVal *label = [self value:o key:@"NSLabel"], *src = [self value:o key:@"NSSource"], *dst = [self value:o key:@"NSDestination"];
        if (!label || label->type != 10 || !src || src->type != 10 || !dst || dst->type != 10) continue;
        NSString *key = [self stringAt:(uint32_t)label->ref];
        id from = [self instantiate:(uint32_t)src->ref delegate:delegate delegateName:delegateName];
        id to = [self instantiate:(uint32_t)dst->ref delegate:delegate delegateName:delegateName];
        if (!key.length || !from || !to || from == NSApp) continue;   // NSApplication's own delegate outlet is set by the caller
        @try { [from setValue:to forKey:key]; } @catch (NSException *e) { NSLog(@"[ShackAppKit] nib outlet %@ failed: %@", key, e.reason); }
        NSLog(@"[ShackAppKit] nib outlet %@.%@ = %@", NSStringFromClass([from class]), key, NSStringFromClass([to class]));
        for (id x in @[from, to]) if (![built containsObject:x]) [built addObject:x];
    }
    for (id x in [built reverseObjectEnumerator])   // views first, the delegate last
        if (x != delegate && [x respondsToSelector:@selector(awakeFromNib)]) [x awakeFromNib];
    if ([delegate respondsToSelector:@selector(awakeFromNib)]) [delegate awakeFromNib];
}
#endif
@end

static NSString *ArchiveDelegate(NSData *data, NSString *appClass) {
    ShackNibArchive *a = [ShackNibArchive parse:data];
    if (!a) return nil;
    for (uint32_t o = 0; o < a.objectCount; o++) {
        if (![[a classOf:o] hasSuffix:@"OutletConnector"] && ![[a classOf:o] isEqualToString:@"NSNibConnector"]) continue;
        NibVal *label = [a value:o key:@"NSLabel"], *src = [a value:o key:@"NSSource"], *dst = [a value:o key:@"NSDestination"];
        if (!label || label->type != 10 || !src || src->type != 10 || !dst || dst->type != 10) continue;
        if (![[a stringAt:(uint32_t)label->ref] isEqualToString:@"delegate"]) continue;
        NSString *srcName = [a nameOf:(uint32_t)src->ref];
        if ([srcName isEqualToString:appClass] || [srcName isEqualToString:@"NSApplication"]) return [a nameOf:(uint32_t)dst->ref];
    }
    return nil;
}

extern uint32_t _CFKeyedArchiverUIDGetValue(CFTypeRef uid);   // CoreFoundation export; the plist nib is a keyed archive
static id PlistObject(NSArray *objs, id uid) { return uid ? objs[_CFKeyedArchiverUIDGetValue((__bridge CFTypeRef)uid)] : nil; }

static NSString *PlistDelegate(NSData *data, NSString *appClass) {
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    NSArray *objs = [root isKindOfClass:NSDictionary.class] ? root[@"$objects"] : nil;
    for (NSDictionary *c in objs) {
        if (![c isKindOfClass:NSDictionary.class] || ![PlistObject(objs, c[@"NSLabel"]) isEqual:@"delegate"]) continue;
        NSDictionary *src = PlistObject(objs, c[@"NSSource"]), *dst = PlistObject(objs, c[@"NSDestination"]);
        if (![src isKindOfClass:NSDictionary.class] || ![dst isKindOfClass:NSDictionary.class]) continue;
        NSString *srcClass = PlistObject(objs, src[@"NSClassName"]);
        if ([srcClass isEqual:appClass] || [srcClass isEqual:@"NSApplication"]) return PlistObject(objs, dst[@"NSClassName"]);
    }
    return nil;
}

// The archive macOS loads from a nib folder: Xcode writes keyedobjects-101300.nib (NIBArchive, macOS 10.13 and later) next
// to keyedobjects.nib (keyed-archive plist, older macOS) when the deployment target predates 10.13 (GameMaker's runner).
static NSData *NibData(NSString *nibPath) {
    BOOL dir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:nibPath isDirectory:&dir] && dir) {
        NSString *modern = [nibPath stringByAppendingPathComponent:@"keyedobjects-101300.nib"];
        nibPath = [NSFileManager.defaultManager fileExistsAtPath:modern] ? modern : [nibPath stringByAppendingPathComponent:@"keyedobjects.nib"];
    }
    return [NSData dataWithContentsOfFile:nibPath];
}

// Class name of the object connected to the application's `delegate` outlet, or nil.
NSString *ShackNibDelegateClass(NSString *nibPath, NSString *appClass) {
    NSData *d = NibData(nibPath);
    if (!d) return nil;
    return ArchiveDelegate(d, appClass) ?: PlistDelegate(d, appClass);
}

#ifndef SHACK_NIB_TEST
// After the delegate exists: build the window and views the nib connects to it and set its outlets (Solar2D's AppDelegate
// finds its `window`, whose content view is a CoronaView, only this way). NIBArchive nibs only.
void ShackNibConnect(NSString *nibPath, id delegate, NSString *delegateName) {
    NSData *d = NibData(nibPath);
    ShackNibArchive *a = d ? [ShackNibArchive parse:d] : nil;
    if (a && delegate) [a connectDelegate:delegate name:delegateName];
    gMainNib = a;
}
#endif
