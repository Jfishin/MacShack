#import "ShackAppKit.h"
// ponytail: menus are invisible on iOS; they only hold state so UE4's menu-building code round-trips.
@class NSMenu;
@interface NSMenuItem : NSObject
+ (NSMenuItem *)separatorItem;
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key;
@property (nonatomic, copy) NSString *title, *keyEquivalent; @property (nonatomic) SEL action; @property (nonatomic, weak) id target;
@property (nonatomic, strong) NSMenu *submenu; @property (nonatomic, weak) NSMenu *menu; @property (nonatomic, readonly) BOOL hasSubmenu;
@property (nonatomic, getter=isEnabled) BOOL enabled; @property (nonatomic) NSInteger state, tag; @property (nonatomic, strong) id representedObject;
@property (nonatomic) NSEventModifierFlags keyEquivalentModifierMask; @property (nonatomic, readonly, getter=isSeparatorItem) BOOL separatorItem;
@end
@interface NSMenu : NSObject
- (instancetype)initWithTitle:(NSString *)title;
@property (nonatomic, copy) NSString *title; @property (nonatomic, weak) id delegate; @property (nonatomic) BOOL autoenablesItems;
@property (nonatomic, weak) NSMenu *supermenu; @property (nonatomic, readonly) NSArray<NSMenuItem *> *itemArray; @property (nonatomic, readonly) NSInteger numberOfItems;
- (void)addItem:(NSMenuItem *)i; - (NSMenuItem *)addItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k;
- (void)insertItem:(NSMenuItem *)i atIndex:(NSInteger)idx; - (void)removeItem:(NSMenuItem *)i; - (void)removeItemAtIndex:(NSInteger)idx; - (void)removeAllItems;
- (NSMenuItem *)itemAtIndex:(NSInteger)idx; - (NSMenuItem *)itemWithTitle:(NSString *)t; - (NSMenuItem *)itemWithTag:(NSInteger)tag;
- (NSInteger)indexOfItem:(NSMenuItem *)i; - (NSInteger)indexOfItemWithTitle:(NSString *)t; - (NSInteger)indexOfItemWithTag:(NSInteger)tag; - (NSInteger)indexOfItemWithSubmenu:(NSMenu *)m;
- (NSMenuItem *)insertItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k atIndex:(NSInteger)idx;
- (void)setSubmenu:(NSMenu *)m forItem:(NSMenuItem *)i; - (void)update;
@end

@implementation NSMenuItem { BOOL _sep; }
SHACK_SAFETY_NET
+ (NSMenuItem *)separatorItem { NSMenuItem *i = [[self alloc] initWithTitle:@"" action:NULL keyEquivalent:@""]; i->_sep = YES; i.enabled = NO; return i; }
- (instancetype)init { return [self initWithTitle:@"" action:NULL keyEquivalent:@""]; }
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key {
    if ((self = [super init])) { _title = [title copy]; _action = action; _keyEquivalent = [key copy]; _enabled = YES; _keyEquivalentModifierMask = NSEventModifierFlagCommand; }
    return self;
}
- (void)setSubmenu:(NSMenu *)m { _submenu = m; m.supermenu = _menu; }
- (BOOL)hasSubmenu { return _submenu != nil; }
- (BOOL)isSeparatorItem { return _sep; }
@end

@implementation NSMenu { NSMutableArray<NSMenuItem *> *_items; }
SHACK_SAFETY_NET
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithTitle:(NSString *)title { if ((self = [super init])) { _title = [title copy]; _items = [NSMutableArray array]; _autoenablesItems = YES; } return self; }
- (NSArray<NSMenuItem *> *)itemArray { return [_items copy]; }
- (NSInteger)numberOfItems { return (NSInteger)_items.count; }
- (void)addItem:(NSMenuItem *)i { [self insertItem:i atIndex:self.numberOfItems]; }
- (NSMenuItem *)addItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k { NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]; [self addItem:i]; return i; }
- (void)insertItem:(NSMenuItem *)i atIndex:(NSInteger)idx { [_items insertObject:i atIndex:(NSUInteger)idx]; i.menu = self; i.submenu.supermenu = self; }
- (void)removeItem:(NSMenuItem *)i { [_items removeObjectIdenticalTo:i]; i.menu = nil; }
- (void)removeItemAtIndex:(NSInteger)idx { [self removeItem:_items[(NSUInteger)idx]]; }
- (void)removeAllItems { for (NSMenuItem *i in _items) i.menu = nil; [_items removeAllObjects]; }
- (NSMenuItem *)itemAtIndex:(NSInteger)idx { return idx >= 0 && idx < self.numberOfItems ? _items[(NSUInteger)idx] : nil; }
- (NSMenuItem *)itemWithTitle:(NSString *)t { for (NSMenuItem *i in _items) if ([i.title isEqualToString:t]) return i; return nil; }
- (NSMenuItem *)itemWithTag:(NSInteger)tag { for (NSMenuItem *i in _items) if (i.tag == tag) return i; return nil; }
- (NSInteger)indexOfItem:(NSMenuItem *)i { NSUInteger x = [_items indexOfObjectIdenticalTo:i]; return x == NSNotFound ? -1 : (NSInteger)x; }
- (NSInteger)indexOfItemWithTitle:(NSString *)t { NSMenuItem *i = [self itemWithTitle:t]; return i ? [self indexOfItem:i] : -1; }
- (NSInteger)indexOfItemWithTag:(NSInteger)tag { NSMenuItem *i = [self itemWithTag:tag]; return i ? [self indexOfItem:i] : -1; }
- (NSInteger)indexOfItemWithSubmenu:(NSMenu *)m { for (NSMenuItem *i in _items) if (i.submenu == m) return [self indexOfItem:i]; return -1; }
- (NSMenuItem *)insertItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k atIndex:(NSInteger)idx {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]; [self insertItem:i atIndex:idx]; return i;
}
- (void)setSubmenu:(NSMenu *)m forItem:(NSMenuItem *)i { i.submenu = m; }
- (void)update {}
@end

// The main menu a keyed-archive main nib holds (`_NSMainMenu`): titles, key equivalents, actions, separators, submenus. Targets
// stay nil, as for a menu whose actions go down the responder chain. Feral Interactive's engine walks NSApp.mainMenu at startup
// and expects its items. NIBArchive nibs (ShackNib.m's other format) build no menus yet.
extern uint32_t _CFKeyedArchiverUIDGetValue(CFTypeRef uid);
static id NibRef(NSArray *objs, id uid) { return uid ? objs[_CFKeyedArchiverUIDGetValue((__bridge CFTypeRef)uid)] : nil; }
static NSMenu *NibMenu(NSArray *objs, NSDictionary *m) {
    NSString *title = NibRef(objs, m[@"NSTitle"]);
    NSMenu *menu = [[NSMenu alloc] initWithTitle:[title isKindOfClass:NSString.class] ? title : @""];
    for (id ref in [NibRef(objs, m[@"NSMenuItems"]) objectForKey:@"NS.objects"]) {
        NSDictionary *it = NibRef(objs, ref);
        if (![it isKindOfClass:NSDictionary.class]) continue;
        if ([it[@"NSIsSeparator"] boolValue]) { [menu addItem:[NSMenuItem separatorItem]]; continue; }
        NSString *t = NibRef(objs, it[@"NSTitle"]), *k = NibRef(objs, it[@"NSKeyEquiv"]), *a = NibRef(objs, it[@"NSAction"]);
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[t isKindOfClass:NSString.class] ? t : @"" action:[a isKindOfClass:NSString.class] && a.length ? NSSelectorFromString(a) : NULL
                                               keyEquivalent:[k isKindOfClass:NSString.class] ? k : @""];
        if (it[@"NSKeyEquivModMask"]) item.keyEquivalentModifierMask = [it[@"NSKeyEquivModMask"] unsignedIntegerValue];
        item.tag = [it[@"NSTag"] integerValue];
        item.enabled = ![it[@"NSIsDisabled"] boolValue];
        NSDictionary *sub = NibRef(objs, it[@"NSSubmenu"]);
        if ([sub isKindOfClass:NSDictionary.class]) item.submenu = NibMenu(objs, sub);
        [menu addItem:item];
    }
    return menu;
}
void ShackNibInstallMainMenu(NSString *nibPath) {
    BOOL dir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:nibPath isDirectory:&dir] && dir) nibPath = [nibPath stringByAppendingPathComponent:@"keyedobjects.nib"];
    NSData *d = [NSData dataWithContentsOfFile:nibPath];
    NSDictionary *root = d ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL] : nil;
    NSArray *objs = [root isKindOfClass:NSDictionary.class] ? root[@"$objects"] : nil;
    for (NSDictionary *o in objs) {
        if (![o isKindOfClass:NSDictionary.class] || ![NibRef(objs, o[@"NSName"]) isEqual:@"_NSMainMenu"]) continue;
        NSDictionary *cls = NibRef(objs, o[@"$class"]);
        if (![cls[@"$classname"] isEqual:@"NSMenu"]) continue;
        NSApplication.sharedApplication.mainMenu = NibMenu(objs, o);
        return;
    }
}
