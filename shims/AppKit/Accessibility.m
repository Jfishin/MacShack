#import "ShackAppKit.h"

// ponytail: no macOS accessibility server on iOS. UE4's FMacAccessibilityElement subclasses this and
// overrides the getters; nothing ever queries them, so everything is a no-op.
@interface NSAccessibilityElement : NSObject
+ (id)accessibilityElementWithRole:(NSString *)role frame:(NSRect)frame label:(NSString *)label parent:(id)parent;
@end
@implementation NSAccessibilityElement
SHACK_SAFETY_NET
+ (id)accessibilityElementWithRole:(NSString *)role frame:(NSRect)frame label:(NSString *)label parent:(id)parent { return [self new]; }
@end

// The NSAccessibility (macOS informal protocol) selectors Lies of P references that UIKit's NSObject(UIAccessibility)
// lacks. accessibilityFrame/Label/Value, setAccessibilityFrame:/Label: and isAccessibilityElement come from UIKit.
@interface NSObject (ShackNSAccessibility)
- (id)accessibilityApplicationFocusedUIElement; - (void)setAccessibilityApplicationFocusedUIElement:(id)e;
- (NSArray *)accessibilityChildren; - (void)setAccessibilityChildren:(NSArray *)c;
- (id)accessibilityParent; - (void)setAccessibilityParent:(id)p;
- (id)accessibilityWindow; - (void)setAccessibilityWindow:(id)w;
- (NSString *)accessibilityRole; - (void)setAccessibilityRole:(NSString *)r;
- (NSString *)accessibilitySubrole; - (void)setAccessibilitySubrole:(NSString *)r;
- (BOOL)isAccessibilityFocused; - (void)setAccessibilityFocused:(BOOL)f;
- (void)setAccessibilityEnabled:(BOOL)f; - (void)setAccessibilityElement:(BOOL)f;
- (id)accessibilityFocusedUIElement; - (NSString *)accessibilityHelp; - (NSString *)accessibilityRoleDescription; - (NSString *)accessibilitySelectedText;
- (NSInteger)accessibilityInsertionPointLineNumber; - (NSInteger)accessibilityNumberOfCharacters; - (NSInteger)accessibilityLineForIndex:(NSInteger)i;
- (NSRange)accessibilityRangeForLine:(NSInteger)l; - (NSRange)accessibilitySelectedTextRange; - (NSRange)accessibilityVisibleCharacterRange;
- (BOOL)accessibilityNotifiesWhenDestroyed; - (BOOL)accessibilityPerformPress; - (BOOL)accessibilityPerformIncrement; - (BOOL)accessibilityPerformDecrement;
- (BOOL)isAccessibilitySelectorAllowed:(SEL)s;
@end
@implementation NSObject (ShackNSAccessibility)
- (id)accessibilityApplicationFocusedUIElement { return nil; } - (void)setAccessibilityApplicationFocusedUIElement:(id)e {}
- (NSArray *)accessibilityChildren { return nil; } - (void)setAccessibilityChildren:(NSArray *)c {}
- (id)accessibilityParent { return nil; } - (void)setAccessibilityParent:(id)p {}
- (id)accessibilityWindow { return nil; } - (void)setAccessibilityWindow:(id)w {}
- (NSString *)accessibilityRole { return nil; } - (void)setAccessibilityRole:(NSString *)r {}
- (NSString *)accessibilitySubrole { return nil; } - (void)setAccessibilitySubrole:(NSString *)r {}
- (BOOL)isAccessibilityFocused { return NO; } - (void)setAccessibilityFocused:(BOOL)f {}
- (void)setAccessibilityEnabled:(BOOL)f {} - (void)setAccessibilityElement:(BOOL)f {}
- (id)accessibilityFocusedUIElement { return nil; } - (NSString *)accessibilityHelp { return nil; }
- (NSString *)accessibilityRoleDescription { return nil; } - (NSString *)accessibilitySelectedText { return nil; }
- (NSInteger)accessibilityInsertionPointLineNumber { return 0; } - (NSInteger)accessibilityNumberOfCharacters { return 0; }
- (NSInteger)accessibilityLineForIndex:(NSInteger)i { return 0; }
- (NSRange)accessibilityRangeForLine:(NSInteger)l { return NSMakeRange(0, 0); }
- (NSRange)accessibilitySelectedTextRange { return NSMakeRange(0, 0); }
- (NSRange)accessibilityVisibleCharacterRange { return NSMakeRange(0, 0); }
- (BOOL)accessibilityNotifiesWhenDestroyed { return NO; }
- (BOOL)accessibilityPerformPress { return NO; } - (BOOL)accessibilityPerformIncrement { return NO; } - (BOOL)accessibilityPerformDecrement { return NO; }
- (BOOL)isAccessibilitySelectorAllowed:(SEL)s { return YES; }
@end
