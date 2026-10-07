// Mac-side check of shims/AppKit/ShackNib.m against real game nibs: the delegate outlet in both compiled formats.
// clang -fobjc-arc -DSHACK_NIB_TEST shims/AppKit/ShackNib.m host/probe/test_nib.m -framework Foundation -o /tmp/n && /tmp/n
#import <Foundation/Foundation.h>
#import <assert.h>
NSString *ShackNibDelegateClass(NSString *nibPath, NSString *appClass);
int main(void) { @autoreleasepool {
    NSString *hades = @"/Volumes/Transcend/SteamLibrary/steamapps/common/Hades II/Hades II.app/Contents/Resources/Base.lproj/MainMenu.nib";
    NSString *silk = @"/Applications/Hollow Knight Silksong/Hollow Knight Silksong.app/Contents/Resources/MainMenu.nib";
    if ([NSFileManager.defaultManager fileExistsAtPath:hades]) {   // binary NIBArchive (newer Xcode)
        NSString *c = ShackNibDelegateClass(hades, @"Backtrace.BacktraceCrashExceptionApplication");
        printf("Hades II: %s\n", c.UTF8String); assert([c isEqualToString:@"AppDelegate"]);
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:silk]) {    // keyed-archive plist (older Xcode, Unity)
        NSString *c = ShackNibDelegateClass(silk, @"PlayerApplication");
        printf("Silksong: %s\n", c.UTF8String); assert([c isEqualToString:@"PlayerAppDelegate"]);
    }
    NSString *coromon = @"build/coromon/nib/Base.lproj/MainMenu.nib";   // pulled from the phone (Documents/Games/Coromon.app)
    if ([NSFileManager.defaultManager fileExistsAtPath:coromon]) {
        NSString *c = ShackNibDelegateClass(coromon, @"NSApplication");
        printf("Coromon: %s\n", c.UTF8String); assert([c isEqualToString:@"AppDelegate"]);
    }
    assert(ShackNibDelegateClass(@"/nonexistent.nib", @"NSApplication") == nil);
    puts("ShackNib checks passed.");
}}
