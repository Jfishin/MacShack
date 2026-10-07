// The on-screen controller's pad (host/TouchControls.swift draws it): a writable GameController pad that games receive
// like a Bluetooth one; ShackHID turns it into its virtual Xbox HID pad for IOKit readers too. Main thread only.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ShackPadButton) {
    ShackPadButtonA, ShackPadButtonB, ShackPadButtonX, ShackPadButtonY, ShackPadButtonLB, ShackPadButtonRB,
    ShackPadButtonLT, ShackPadButtonRT, ShackPadButtonMenu, ShackPadButtonView, ShackPadButtonL3, ShackPadButtonR3,
};
void ShackTouchPadSetConnected(BOOL connected);                 // announce / remove (releases everything first)
void ShackTouchPadButton(ShackPadButton button, BOOL pressed);
void ShackTouchPadStick(NSInteger stick, float x, float y);    // 0 left, 1 right; -1...1, up is +y
void ShackTouchPadDpad(float x, float y);                       // -1, 0 or 1 each; up is +y
void ShackTouchPadReleaseAll(void);
void ShackTouchPadSetTouching(BOOL touching);                 // a finger is on the controls (frame-pacing stats)
BOOL ShackTouchPadTouching(void);                               // any thread
