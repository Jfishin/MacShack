// Mac check for host/ShackTouchPad.m, the on-screen controller's GameController pad:
// clang -fobjc-arc host/ShackTouchPad.m host/probe/test_touch_pad.m -framework GameController -framework Foundation -o /tmp/t && /tmp/t
#import <GameController/GameController.h>
#import "../ShackTouchPad.h"
#include <stdio.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)
static void spin(void) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }

int main(void) { @autoreleasepool {
    __block GCController *connected = nil, *gone = nil;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { connected = n.object; }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { gone = n.object; }];
    ShackTouchPadButton(ShackPadButtonA, YES);   // hidden: dropped
    ShackTouchPadSetConnected(YES);
    GCController *pad = connected; spin(); CHECK(pad);   // posted synchronously; a real pad may connect after it
    CHECK([GCController.controllers containsObject:pad] && GCController.current != nil);
    CHECK([pad.productCategory isEqual:@"Xbox One"] && [pad.vendorName isEqual:@"Xbox Wireless Controller"]);
    GCExtendedGamepad *g = pad.extendedGamepad;
    CHECK(!g.buttonA.isPressed);
    __block int profile = 0, aPressed = 0; __block GCControllerElement *last = nil;
    g.valueChangedHandler = ^(GCExtendedGamepad *p, GCControllerElement *e) { profile++; last = e; };
    g.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { aPressed++; };
    ShackTouchPadButton(ShackPadButtonA, YES); spin();
    CHECK(g.buttonA.isPressed && aPressed == 1 && profile == 1 && last == g.buttonA);
    ShackTouchPadButton(ShackPadButtonA, YES); spin();
    CHECK(profile == 1);   // unchanged: nothing sent
    ShackTouchPadDpad(-1, 1); ShackTouchPadStick(0, 0.5f, -0.25f); ShackTouchPadStick(1, -1, 0);
    ShackTouchPadButton(ShackPadButtonRT, YES); ShackTouchPadButton(ShackPadButtonView, YES); ShackTouchPadButton(ShackPadButtonL3, YES); spin();
    CHECK(g.dpad.left.isPressed && g.dpad.up.isPressed && !g.dpad.right.isPressed);
    CHECK(g.leftThumbstick.xAxis.value == 0.5f && g.leftThumbstick.yAxis.value == -0.25f && g.rightThumbstick.xAxis.value == -1);
    CHECK(g.rightTrigger.value == 1 && g.buttonOptions.isPressed && g.leftThumbstickButton.isPressed);
    CHECK(profile == 7);   // A, d-pad, two sticks, RT, View, L3
    ShackTouchPadSetConnected(NO); spin();
    CHECK(gone == pad && ![GCController.controllers containsObject:pad]);
    CHECK(!g.buttonA.isPressed && !g.dpad.left.isPressed && g.leftThumbstick.xAxis.value == 0 && g.rightTrigger.value == 0);
    connected = nil; ShackTouchPadSetConnected(YES);
    CHECK(connected == pad);   // the same pad comes back
    ShackTouchPadSetConnected(NO);
    puts("touch pad ok");
} return 0; }
