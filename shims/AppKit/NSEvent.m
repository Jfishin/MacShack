#import "ShackAppKit.h"
static NSPoint gMouse;
static NSUInteger gButtons; static NSEventModifierFlags gModifiers; static NSInteger gEventCounter;   // main thread writes
static NSMutableArray<NSArray *> *gLocalMonitors;   // @[@(mask), handler]; main thread only

@implementation NSEvent
SHACK_SAFETY_NET
+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(NSEvent *(^)(NSEvent *))h {
    NSArray *m = @[@(mask), [h copy]];
    ShackMainSync(^{ if (!gLocalMonitors) gLocalMonitors = [NSMutableArray array]; [gLocalMonitors addObject:m]; });
    return m;
}
// ponytail: global monitors see other apps' events; there are none on iOS, so they're accepted and never fire.
+ (id)addGlobalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(void (^)(NSEvent *))h { return [NSObject new]; }
+ (void)removeMonitor:(id)m { ShackMainSync(^{ [gLocalMonitors removeObjectIdenticalTo:m]; }); }
+ (NSEvent *)shack_runLocalMonitors:(NSEvent *)e {   // main thread
    for (NSArray *m in [gLocalMonitors copy]) {
        if (!((1ULL << e.type) & [m[0] unsignedLongLongValue])) continue;
        NSEvent *(^h)(NSEvent *) = m[1]; if (!(e = h(e))) return nil;
    }
    return e;
}
+ (NSPoint)mouseLocation { return gMouse; }
+ (void)shack_setMouseLocation:(NSPoint)p { gMouse = p; }
+ (NSUInteger)pressedMouseButtons { return gButtons; }
+ (void)shack_setPressedMouseButtons:(NSUInteger)b { gButtons = b; }
+ (NSEventModifierFlags)modifierFlags { return gModifiers; }
+ (void)shack_setModifierFlags:(NSEventModifierFlags)m { gModifiers = m; }
+ (NSTimeInterval)doubleClickInterval { return 0.5; }
+ (NSTimeInterval)keyRepeatDelay { return 0.5; }
+ (NSTimeInterval)keyRepeatInterval { return 1.0 / 30; }
+ (BOOL)isMouseCoalescingEnabled { return YES; }
+ (void)setMouseCoalescingEnabled:(BOOL)f {}
+ (void)startPeriodicEventsAfterDelay:(NSTimeInterval)d withPeriod:(NSTimeInterval)p {}
+ (void)stopPeriodicEvents {}
- (instancetype)init { if ((self = [super init])) _eventNumber = ++gEventCounter; return self; }
+ (NSEvent *)otherEventWithType:(NSEventType)t location:(NSPoint)p modifierFlags:(NSEventModifierFlags)m timestamp:(NSTimeInterval)ts
                    windowNumber:(NSInteger)wn context:(id)c subtype:(short)st data1:(NSInteger)d1 data2:(NSInteger)d2 {
    NSEvent *e = [self new]; e.type = t; e.locationInWindow = p; e.modifierFlags = m; e.timestamp = ts; e.windowNumber = wn;
    e.subtype = st; e.data1 = d1; e.data2 = d2; return e;
}
+ (NSEvent *)keyEventWithType:(NSEventType)t location:(NSPoint)p modifierFlags:(NSEventModifierFlags)m timestamp:(NSTimeInterval)ts
                 windowNumber:(NSInteger)wn context:(id)c characters:(NSString *)ch charactersIgnoringModifiers:(NSString *)chim isARepeat:(BOOL)r keyCode:(unsigned short)k {
    NSEvent *e = [self new]; e.type = t; e.locationInWindow = p; e.modifierFlags = m; e.timestamp = ts; e.windowNumber = wn;
    e.characters = ch; e.charactersIgnoringModifiers = chim; e.isARepeat = r; e.keyCode = k; return e;
}
+ (NSEvent *)mouseEventWithType:(NSEventType)t location:(NSPoint)p modifierFlags:(NSEventModifierFlags)m timestamp:(NSTimeInterval)ts
                   windowNumber:(NSInteger)wn context:(id)c eventNumber:(NSInteger)en clickCount:(NSInteger)cc pressure:(float)pr {
    NSEvent *e = [self new]; e.type = t; e.locationInWindow = p; e.modifierFlags = m; e.timestamp = ts; e.windowNumber = wn;
    e.clickCount = cc; return e;
}
- (NSInteger)windowNumber { return _windowNumber ?: self.window.windowNumber; }
- (float)pressure { return (_type == NSEventTypeLeftMouseDown || _type == NSEventTypeLeftMouseDragged) ? 1 : 0; }
- (BOOL)hasPreciseScrollingDeltas { return NO; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSUInteger)phase { return 0; } - (NSUInteger)momentumPhase { return 0; }   // NSEventPhaseNone
- (NSInteger)trackingNumber { return 0; }
- (CGFloat)magnification { return 0; } - (CGFloat)rotation { return 0; } - (CGFloat)deltaZ { return 0; }
- (NSUInteger)buttonMask { return 0; }
- (void *)CGEvent { return NULL; }   // CGEventRef; no CGEvent on iOS
- (NSString *)charactersByApplyingModifiers:(NSEventModifierFlags)m { return (m & NSEventModifierFlagShift) ? self.characters.uppercaseString : self.charactersIgnoringModifiers; }
@end
