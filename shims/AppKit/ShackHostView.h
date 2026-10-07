#import "ShackAppKit.h"
/// The UIView that backs an NSWindow. Touches become mouse events, hardware keys become key events,
/// both delivered to the window's responder chain on the main thread.
@interface ShackHostView : UIView
@property (nonatomic, weak) NSWindow *nsWindow;
/// Attach guest content; an opt-in virtual desktop is fitted inside the physical host.
- (void)shack_setGuestView:(UIView *)view;
/// Shows or hides the iOS keyboard; what is typed arrives as key events, like a hardware keyboard. Main thread.
- (void)toggleKeyboard;
@end
