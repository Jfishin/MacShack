#import "ShackAppKit.h"
// Only plain strings cross to UIPasteboard; other types read as absent.
@interface NSPasteboardItem : NSObject
- (NSString *)stringForType:(NSString *)type;
@property (nonatomic, copy) NSString *shack_string;
@end
@implementation NSPasteboardItem
SHACK_SAFETY_NET
- (NSString *)stringForType:(NSString *)type { return [type isEqualToString:NSPasteboardTypeString] ? _shack_string : nil; }
@end

@interface NSPasteboard : NSObject
+ (NSPasteboard *)generalPasteboard;
@property (nonatomic, readonly) NSArray<NSString *> *types; @property (nonatomic, readonly) NSArray<NSPasteboardItem *> *pasteboardItems;
- (NSString *)stringForType:(NSString *)type; - (BOOL)setString:(NSString *)s forType:(NSString *)type;
- (NSInteger)clearContents; - (NSInteger)declareTypes:(NSArray<NSString *> *)types owner:(id)owner;
- (BOOL)writeObjects:(NSArray *)objects; - (NSString *)availableTypeFromArray:(NSArray<NSString *> *)types;
@end
@implementation NSPasteboard
SHACK_SAFETY_NET
+ (NSPasteboard *)generalPasteboard { static NSPasteboard *p; static dispatch_once_t o; dispatch_once(&o, ^{ p = [self new]; }); return p; }
- (NSString *)stringForType:(NSString *)type { return [type isEqualToString:NSPasteboardTypeString] ? UIPasteboard.generalPasteboard.string : nil; }
- (BOOL)setString:(NSString *)s forType:(NSString *)type {
    if (![type isEqualToString:NSPasteboardTypeString]) return NO;
    UIPasteboard.generalPasteboard.string = s; return YES;
}
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.items = @[]; return UIPasteboard.generalPasteboard.changeCount; }
- (NSInteger)declareTypes:(NSArray<NSString *> *)types owner:(id)owner { return [self clearContents]; }
- (NSArray<NSString *> *)types { return UIPasteboard.generalPasteboard.hasStrings ? @[NSPasteboardTypeString] : @[]; }
- (NSArray<NSPasteboardItem *> *)pasteboardItems {
    NSString *s = UIPasteboard.generalPasteboard.string; if (!s) return @[];
    NSPasteboardItem *i = [NSPasteboardItem new]; i.shack_string = s; return @[i];
}
- (BOOL)writeObjects:(NSArray *)objects {
    for (id o in objects) if ([o isKindOfClass:NSString.class]) return [self setString:o forType:NSPasteboardTypeString];
    return NO;
}
- (NSString *)availableTypeFromArray:(NSArray<NSString *> *)types { NSArray *have = self.types; for (NSString *t in types) if ([have containsObject:t]) return t; return nil; }
@end
