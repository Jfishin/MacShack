#import "ShackTouchPad.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>

// +controllerWithExtendedGamepad is the public writable pad. Probed 2026-09-30 (macOS 27, iOS 26.4 simulator): element
// handlers fire for written values but the profile's valueChangedHandler does not; the d-pad takes values only through
// its axes; the pad is not in +controllers/+current; and overriding isSnapshot to NO stops setValue: working.
static GCController *gPad;
static BOOL gConnected;

static GCController *Pad(void) {
    if (gPad) return gPad;
    gPad = [GCController controllerWithExtendedGamepad];
    // A Bluetooth Xbox pad's identity: Xbox prompts in games, the same pad ShackHID reports over IOKit.
    Class sub = objc_allocateClassPair(object_getClass(gPad), "ShackTouchPadController", 0);
    class_addMethod(sub, @selector(vendorName), imp_implementationWithBlock(^NSString *(id s) { return @"Xbox Wireless Controller"; }), "@@:");
    class_addMethod(sub, @selector(productCategory), imp_implementationWithBlock(^NSString *(id s) { return @"Xbox One"; }), "@@:");
    objc_registerClassPair(sub);
    object_setClass(gPad, sub);
    // Games find pads through +controllers and +current; the framework does not list a pad it did not connect.
    Method list = class_getClassMethod(GCController.class, @selector(controllers));
    NSArray *(*origList)(id, SEL) = (void *)method_getImplementation(list);
    method_setImplementation(list, imp_implementationWithBlock(^NSArray *(id cls) {
        NSArray *all = origList(cls, @selector(controllers));
        return gConnected ? [all arrayByAddingObject:gPad] : all;
    }));
    Method cur = class_getClassMethod(GCController.class, @selector(current));
    GCController *(*origCur)(id, SEL) = (void *)method_getImplementation(cur);
    method_setImplementation(cur, imp_implementationWithBlock(^GCController *(id cls) {
        return origCur(cls, @selector(current)) ?: (gConnected ? gPad : nil);
    }));
    return gPad;
}

// What the framework does for a real pad's element and skips for a written one: the profile handler, on the pad's queue.
static void Changed(GCControllerElement *e) {
    GCExtendedGamepad *g = gPad.extendedGamepad;
    GCExtendedGamepadValueChangedHandler h = g.valueChangedHandler;
    if (h) dispatch_async(gPad.handlerQueue ?: dispatch_get_main_queue(), ^{ h(g, e); });
}

static GCControllerButtonInput *Input(ShackPadButton b) {
    GCExtendedGamepad *g = gPad.extendedGamepad;
    switch (b) {
        case ShackPadButtonA: return g.buttonA;
        case ShackPadButtonB: return g.buttonB;
        case ShackPadButtonX: return g.buttonX;
        case ShackPadButtonY: return g.buttonY;
        case ShackPadButtonLB: return g.leftShoulder;
        case ShackPadButtonRB: return g.rightShoulder;
        case ShackPadButtonLT: return g.leftTrigger;
        case ShackPadButtonRT: return g.rightTrigger;
        case ShackPadButtonMenu: return g.buttonMenu;
        case ShackPadButtonView: return g.buttonOptions;
        case ShackPadButtonL3: return g.leftThumbstickButton;
        case ShackPadButtonR3: return g.rightThumbstickButton;
    }
    return nil;
}

void ShackTouchPadButton(ShackPadButton b, BOOL pressed) {
    GCControllerButtonInput *in = gConnected ? Input(b) : nil;
    if (!in || in.isPressed == pressed) return;
    [in setValue:pressed ? 1 : 0];
    Changed(in);
}

static void Axes(GCControllerDirectionPad *d, float x, float y) {
    if (!gConnected || (d.xAxis.value == x && d.yAxis.value == y)) return;
    [d setValueForXAxis:x yAxis:y];
    Changed(d);
}
void ShackTouchPadStick(NSInteger stick, float x, float y) {
    Axes(stick ? gPad.extendedGamepad.rightThumbstick : gPad.extendedGamepad.leftThumbstick, x, y);
}
void ShackTouchPadDpad(float x, float y) { Axes(gPad.extendedGamepad.dpad, x, y); }

static _Atomic BOOL gTouching;
void ShackTouchPadSetTouching(BOOL touching) { gTouching = touching; }
BOOL ShackTouchPadTouching(void) { return gTouching; }
void ShackTouchPadReleaseAll(void) {
    for (ShackPadButton b = ShackPadButtonA; b <= ShackPadButtonR3; b++) ShackTouchPadButton(b, NO);
    ShackTouchPadStick(0, 0, 0); ShackTouchPadStick(1, 0, 0); ShackTouchPadDpad(0, 0);
}

void ShackTouchPadSetConnected(BOOL on) {
    if (on == gConnected) return;
    GCController *pad = Pad();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (on) {
        gConnected = YES;
        [nc postNotificationName:GCControllerDidConnectNotification object:pad];
        if (GCController.current == pad) [nc postNotificationName:GCControllerDidBecomeCurrentNotification object:pad];
    } else {
        ShackTouchPadReleaseAll();   // games see the releases before the pad leaves: nothing stays held
        BOOL current = GCController.current == pad;
        gConnected = NO;
        if (current) [nc postNotificationName:GCControllerDidStopBeingCurrentNotification object:pad];
        [nc postNotificationName:GCControllerDidDisconnectNotification object:pad];
    }
}
