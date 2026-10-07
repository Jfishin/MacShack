// Mac-side check of the virtual HID gamepad (shims/IOKit/ShackHID.m): matching, properties, raw reports in the byte
// layout Unity's XboxOneGampadMacOSWireless reads, element values, queues, type ids.
// clang -fobjc-arc -DSHACK_HID_TEST shims/IOKit/ShackHID.m host/probe/test_shack_hid.m -framework Foundation -framework GameController -o /tmp/t && /tmp/t
#import <Foundation/Foundation.h>
#import <assert.h>
#import <objc/message.h>
#import <dlfcn.h>

void *IOHIDManagerCreate(CFAllocatorRef, uint32_t);
void IOHIDManagerSetDeviceMatchingMultiple(void *, CFArrayRef);
void IOHIDManagerRegisterDeviceMatchingCallback(void *, void (*)(void *, int32_t, void *, void *), void *);
void IOHIDManagerScheduleWithRunLoop(void *, CFRunLoopRef, CFStringRef);
int32_t IOHIDManagerOpen(void *, uint32_t);
CFSetRef IOHIDManagerCopyDevices(void *);
CFTypeRef IOHIDDeviceGetProperty(void *, CFStringRef);
void IOHIDDeviceRegisterInputReportCallback(void *, uint8_t *, CFIndex, void (*)(void *, int32_t, void *, uint32_t, uint32_t, uint8_t *, CFIndex), void *);
CFArrayRef IOHIDDeviceCopyMatchingElements(void *, CFDictionaryRef, uint32_t);
int32_t IOHIDDeviceGetValue(void *, void *, void **);
CFIndex IOHIDValueGetIntegerValue(void *);
void *IOHIDQueueCreate(CFAllocatorRef, void *, CFIndex, uint32_t);
void IOHIDQueueAddElement(void *, void *);
void IOHIDQueueStart(void *);
void IOHIDQueueStop(void *);
CFIndex IOHIDQueueGetDepth(void *);
void *IOHIDQueueCopyNextValueWithTimeout(void *, CFTimeInterval);
void *IOHIDValueGetElement(void *);
CFTypeID IOHIDElementGetTypeID(void);
uint32_t IOHIDElementGetType(void *);
CFArrayRef IOHIDElementGetChildren(void *);
int IOServiceGetMatchingServices(uint32_t, CFDictionaryRef, uint32_t *);
uint32_t IOIteratorNext(uint32_t);
int IORegistryEntryGetRegistryEntryID(uint32_t, uint64_t *);
uint32_t IOServiceGetMatchingService(uint32_t, CFDictionaryRef);
int IOObjectRelease(uint32_t);
int IORegistryEntryCreateCFProperties(uint32_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
void *IOHIDDeviceCreate(CFAllocatorRef, uint32_t);
uint32_t IOHIDDeviceGetService(void *);
void *ShackHIDTestAddPad(void);
void ShackHIDTestSet(void *, float, float, float, BOOL, BOOL, uint32_t);
void ShackHIDTestRemovePads(void);
int IOServiceAddMatchingNotification(struct IONotificationPort *, const char *, CFDictionaryRef, void (*)(void *, uint32_t), void *, uint32_t *);

static void *gMatched; static uint8_t gReport[64]; static CFIndex gReportLen;
static void matched(void *ctx, int32_t r, void *sender, void *dev) { gMatched = dev; }
static void report(void *ctx, int32_t r, void *sender, uint32_t type, uint32_t id, uint8_t *rep, CFIndex len) { gReportLen = len; }
// The host's answer to "is this the second guest's code" (a game the Steam client started), which ShackHID looks up.
static BOOL gSecondCaller; static CFIndex gGameLen;
static BOOL isSecondCaller(const void *pc) { return gSecondCaller; }
void ShackHIDSetSecondGuestTest(BOOL (*)(const void *));
void ShackHIDForgetSecondGuest(void);
static void gameReport(void *ctx, int32_t r, void *sender, uint32_t type, uint32_t id, uint8_t *rep, CFIndex len) { gGameLen = len; }
// SDL 2.28 HIDAPI's CallbackIOServiceFunc: it rescans only for entries it drains, so an empty iterator changes nothing
static int gArrivals, gRemovals, gKeyboardArrivals;
static void hidChanged(void *ctx, uint32_t it) { for (uint32_t o; (o = IOIteratorNext(it)); ) { IOObjectRelease(o); ++*(int *)ctx; } }
static void spin(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false); }
static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t u16(const uint8_t *p) { return p[0] | p[1] << 8; }
static void *element(void *dev, int page, int usage) {
    CFArrayRef a = IOHIDDeviceCopyMatchingElements(dev, (__bridge CFDictionaryRef)@{@"UsagePage": @(page), @"Usage": @(usage)}, 0);
    assert(a && CFArrayGetCount(a) == 1); void *e = (void *)CFArrayGetValueAtIndex(a, 0); CFRelease(a); return e;
}

int main(void) { @autoreleasepool {
    void *mgr = IOHIDManagerCreate(NULL, 0);
    IOHIDManagerSetDeviceMatchingMultiple(mgr, (__bridge CFArrayRef)@[@{@"DeviceUsagePage": @1, @"DeviceUsage": @4}, @{@"DeviceUsagePage": @1, @"DeviceUsage": @5}]);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matched, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    assert(IOHIDManagerOpen(mgr, 0) == 0);
    // A scheduled manager keeps its run loop alive: Unity's input thread schedules its manager, calls CFRunLoopRun(),
    // and quits if that returns. A fresh thread's loop is empty (the main loop always has the dispatch port).
    __block CFRunLoopRunResult threadResult = 0; dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [NSThread detachNewThreadWithBlock:^{
        void *m2 = IOHIDManagerCreate(NULL, 0); IOHIDManagerOpen(m2, 0);
        IOHIDManagerScheduleWithRunLoop(m2, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        threadResult = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    assert(threadResult == kCFRunLoopRunTimedOut);
    void *byPage = IOHIDManagerCreate(NULL, 0);      // usage page alone matches through DeviceUsagePairs
    IOHIDManagerSetDeviceMatchingMultiple(byPage, (__bridge CFArrayRef)@[@{@"DeviceUsagePage": @1}]);
    void *keyboards = IOHIDManagerCreate(NULL, 0);   // a keyboard-only manager must not see the pad
    IOHIDManagerSetDeviceMatchingMultiple(keyboards, (__bridge CFArrayRef)@[@{@"DeviceUsagePage": @1, @"DeviceUsage": @6}]);
    IOHIDManagerOpen(keyboards, 0);

    // SDL's HIDAPI is told about HID arrivals and removals through IOKit notifications (Mina the Hollower: a pad connected
    // mid-game was never seen); a keyboard watcher must not hear about the pad
    struct IONotificationPort *port = ((struct IONotificationPort *(*)(uint32_t))dlsym(dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW), "IONotificationPortCreate"))(0);
    uint32_t ignored;
    assert(IOServiceAddMatchingNotification(port, "IOServiceFirstMatch", CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice"}), hidChanged, &gArrivals, &ignored) == 0);
    assert(IOServiceAddMatchingNotification(port, "IOServiceTerminate", CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice"}), hidChanged, &gRemovals, &ignored) == 0);
    assert(IOServiceAddMatchingNotification(port, "IOServiceFirstMatch", CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice", @"PrimaryUsage": @6}), hidChanged, &gKeyboardArrivals, &ignored) == 0);

    void *dev = ShackHIDTestAddPad(); spin();
    assert(gMatched == dev);
    assert(gArrivals == 1 && gRemovals == 0 && gKeyboardArrivals == 0);
    assert(IOHIDManagerCopyDevices(keyboards) == NULL);
    CFSetRef paged = IOHIDManagerCopyDevices(byPage); assert(paged && CFSetGetCount(paged) == 1); CFRelease(paged);
    CFSetRef all = IOHIDManagerCopyDevices(mgr); assert(all && CFSetGetCount(all) == 1); CFRelease(all);
    assert(IOHIDDeviceGetProperty(dev, CFSTR("DeviceUsage")) == NULL);   // real devices only have it inside DeviceUsagePairs
    assert([(__bridge id)IOHIDDeviceGetProperty(dev, CFSTR("VendorID")) intValue] == 1118);
    // SHACK_HID_PAD=xbox2016 (run this check with and without it): the 2016 firmware, 17 HID buttons with View as button 17,
    // which Rewired matches by product id and button count; otherwise 02fd with View on Consumer AC Back
    BOOL pad2016 = getenv("SHACK_HID_PAD") && !strcmp(getenv("SHACK_HID_PAD"), "xbox2016");
    assert([(__bridge id)IOHIDDeviceGetProperty(dev, CFSTR("ProductID")) intValue] == (pad2016 ? 736 : 765));   // both in Unity's XboxOneGampadMacOSWireless list
    CFArrayRef buttons = IOHIDDeviceCopyMatchingElements(dev, (__bridge CFDictionaryRef)@{@"Type": @2}, 0);
    assert(buttons && CFArrayGetCount(buttons) == (pad2016 ? 17 : 16)); CFRelease(buttons);
    NSString *product = (__bridge id)IOHIDDeviceGetProperty(dev, CFSTR("Product"));
    assert([product rangeOfString:@"Xbox.*Wireless Controller" options:NSRegularExpressionSearch].location == 0);

    // Rewired finds the pad again in the IORegistry and makes its own device from the service; other classes are real IOKit
    uint32_t it = 0;
    assert(IOServiceGetMatchingServices(0, CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice", @"VendorID": @0x45E, @"ProductID": pad2016 ? @0x2E0 : @0x2FD}), &it) == 0);
    uint32_t service = IOIteratorNext(it);
    assert(service && IOIteratorNext(it) == 0 && IOObjectRelease(it) == 0);
    // SDL's hidapi path ("DevSrvsID:<entry id>"): the entry id, then a lookup by it, gives the same service back.
    uint64_t entryID = 0;
    assert(IORegistryEntryGetRegistryEntryID(service, &entryID) == 0 && entryID);
    assert(IOServiceGetMatchingService(0, CFBridgingRetain(@{@"IORegistryEntryID": @(entryID)})) == service);
    void *made = IOHIDDeviceCreate(NULL, service);
    assert(made == dev && IOHIDDeviceGetService(dev) == service); CFRelease(made);
    // Feral's IndirectX (BioShock) matches by PrimaryUsage and reads the service's properties; it has no path for a failed read
    assert(IOServiceGetMatchingServices(0, CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice", @"PrimaryUsagePage": @1, @"PrimaryUsage": @5}), &it) == 0);
    assert(IOIteratorNext(it) == service && IOIteratorNext(it) == 0); IOObjectRelease(it);
    CFMutableDictionaryRef regProps = NULL;
    assert(IORegistryEntryCreateCFProperties(service, &regProps, NULL, 0) == 0 && regProps);
    assert([((__bridge NSDictionary *)regProps)[@"ProductID"] intValue] == (pad2016 ? 736 : 765)); CFRelease(regProps);
    assert(IOServiceGetMatchingServices(0, CFBridgingRetain(@{@"IOProviderClass": @"IOHIDDevice", @"ProductID": @0x1234}), &it) == 0 && IOIteratorNext(it) == 0);
    IOObjectRelease(it);
    assert(IOServiceGetMatchingServices(0, CFBridgingRetain(@{@"IOProviderClass": @"IOPlatformExpertDevice"}), &it) == 0);
    uint32_t platform = IOIteratorNext(it);
    assert(platform && platform != service && IOHIDDeviceCreate(NULL, platform) == NULL);
    IOObjectRelease(platform); IOObjectRelease(it);

    IOHIDDeviceRegisterInputReportCallback(dev, gReport, sizeof gReport, report, NULL); spin();
    assert(gReportLen == 18 && gReport[0] == 1 && u16(gReport + 1) == 32768);   // current state arrives on registration
    void *q = IOHIDQueueCreate(NULL, dev, 8, 0); void *hatElem = element(dev, 1, 0x39), *xElem = element(dev, 1, 0x30);
    IOHIDQueueAddElement(q, hatElem); IOHIDQueueAddElement(q, xElem); IOHIDQueueStart(q);
    // a starting queue gets each queued element's current value (centered x, not 0 = full left)
    void *first = IOHIDQueueCopyNextValueWithTimeout(q, 0), *second = IOHIDQueueCopyNextValueWithTimeout(q, 0);
    assert(first && second && IOHIDQueueCopyNextValueWithTimeout(q, 0) == NULL);
    assert(IOHIDValueGetIntegerValue(IOHIDValueGetElement(first) == xElem ? first : second) == 32768); CFRelease(first); CFRelease(second);
    gReportLen = 0;
    // left stick full right + up, left trigger full, d-pad up+right, A + Menu + View
    ShackHIDTestSet(dev, 1, 1, 1, YES, YES, 1 << 0 | 1 << 11 | 1 << 16); spin();
    assert(gReportLen == 18 && gReport[0] == 1);
    assert(u16(gReport + 1) == 65535 && u16(gReport + 3) == 0);        // x right, y up (HID y grows downward)
    assert(u16(gReport + 5) == 32768 && u16(gReport + 7) == 32768);    // right stick centered
    assert(u16(gReport + 9) == 1023 && u16(gReport + 11) == 0);        // triggers: 10 bits
    assert(gReport[13] == 2);                                          // hat north-east
    assert(u32(gReport + 14) == (1u << 0 | 1u << 11 | 1u << 16));      // Unity: buttonSouth bit 0, start bit 11, select bit 16

    void *v; assert(IOHIDDeviceGetValue(dev, element(dev, 9, 1), &v) == 0 && IOHIDValueGetIntegerValue(v) == 1);   // button 1 = A
    assert(IOHIDDeviceGetValue(dev, element(dev, 9, 12), &v) == 0 && IOHIDValueGetIntegerValue(v) == 1);           // button 12 = Menu
    void *view = pad2016 ? element(dev, 9, 17) : element(dev, 0x0C, 0x224);                                        // View: button 17 or AC Back
    assert(IOHIDDeviceGetValue(dev, view, &v) == 0 && IOHIDValueGetIntegerValue(v) == 1);
    assert(IOHIDDeviceGetValue(dev, element(dev, 1, 0x30), &v) == 0 && IOHIDValueGetIntegerValue(v) == 65535);
    void *qv = IOHIDQueueCopyNextValueWithTimeout(q, 0);                // x changed first (element order), then the hat
    assert(qv && IOHIDValueGetElement(qv) == xElem && IOHIDValueGetIntegerValue(qv) == 65535); CFRelease(qv);
    qv = IOHIDQueueCopyNextValueWithTimeout(q, 0);
    assert(qv && IOHIDValueGetElement(qv) == hatElem && IOHIDValueGetIntegerValue(qv) == 2); CFRelease(qv);
    assert(IOHIDQueueCopyNextValueWithTimeout(q, 0) == NULL);           // only queued elements, only changes

    ShackHIDTestSet(dev, 0, 0, 0, NO, NO, 0); spin();
    assert(gReport[13] == 0 && u32(gReport + 14) == 0);
    qv = IOHIDQueueCopyNextValueWithTimeout(q, 0); assert(qv && IOHIDValueGetIntegerValue(qv) == 32768); CFRelease(qv);   // x back to center
    qv = IOHIDQueueCopyNextValueWithTimeout(q, 0); assert(qv && IOHIDValueGetIntegerValue(qv) == 0); CFRelease(qv);       // hat released

    // Rewired stops and releases its queue, and its timer polls it once more (Blasphemous): the queue outlives the
    // release and reads empty. MallocScribble=1 makes a freed object fail loudly.
    void *gone = IOHIDQueueCreate(NULL, dev, 8, 0); IOHIDQueueStart(gone); IOHIDQueueStop(gone); CFRelease(gone);
    assert(IOHIDQueueGetDepth(gone) == 8 && IOHIDQueueCopyNextValueWithTimeout(gone, 0) == NULL);

    // A report queued for an older registration is dropped: SDL's HIDAPI re-registers (or closes) and frees that buffer
    uint8_t stale[18]; memset(stale, 0xAA, sizeof stale);
    IOHIDDeviceRegisterInputReportCallback(dev, stale, sizeof stale, report, NULL);   // queues the current report for stale
    IOHIDDeviceRegisterInputReportCallback(dev, gReport, sizeof gReport, report, NULL); spin();
    for (size_t i = 0; i < sizeof stale; i++) assert(stale[i] == 0xAA);
    assert(gReportLen == 18);

    // Two guests in one process (Steam and a game it started) each keep their own report callback on the pad, as two Mac
    // processes do; the game's goes when it ends.
    static uint8_t gameBuf[64]; ShackHIDSetSecondGuestTest(isSecondCaller);
    gSecondCaller = YES; IOHIDDeviceRegisterInputReportCallback(dev, gameBuf, sizeof gameBuf, gameReport, NULL); gSecondCaller = NO; spin();
    gReportLen = gGameLen = 0;
    ShackHIDTestSet(dev, 0, 0, 0, NO, NO, 1); spin();
    assert(gReportLen == 18 && gGameLen == 18);
    ShackHIDForgetSecondGuest();
    gReportLen = gGameLen = 0;
    ShackHIDTestSet(dev, 0, 0, 0, NO, NO, 0); spin();
    assert(gReportLen == 18 && gGameLen == 0);

    // GameController is asked about our device, not real IOKit
    assert(((BOOL (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"GCController"), NSSelectorFromString(@"supportsHIDDevice:"), (__bridge id)dev));

    CFArrayRef els = IOHIDDeviceCopyMatchingElements(dev, NULL, 0);
    void *app = (void *)CFArrayGetValueAtIndex(els, 0);
    assert(IOHIDElementGetType(app) == 513 && CFArrayGetCount(IOHIDElementGetChildren(app)) == CFArrayGetCount(els) - 1);
    assert(CFGetTypeID(app) == IOHIDElementGetTypeID() && IOHIDElementGetTypeID() != 0);   // matches the real IOKit type id
    CFRelease(els);
    ShackHIDTestRemovePads(); spin();
    assert(gRemovals == 1 && gArrivals == 1);
    puts("ShackHID checks passed: matching, open by registry entry id, identity, raw report layout, element values, queues, type ids, arrival/removal notifications, one client per guest.");
}}
