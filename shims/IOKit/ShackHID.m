// Virtual HID gamepads for guests whose macOS input stack reads IOKit HID (Unity's Input System, InControl's native
// plugin, SDL, most custom engines). An iOS app cannot open IOHIDManager, so every IOHIDManager/Device/Element/Value/
// Queue call a guest makes lands here, and each GameController pad appears as one HID device.
//
// Identity: Xbox Wireless Controller over Bluetooth, firmware 4.8 (045e:02fd). macOS game stacks know it by vendor/
// product id (Unity's XboxOneGampadMacOSWireless layout matches it and reads the raw report below byte for byte), so
// any GameController pad gets working default bindings with no per-game work.
// ponytail: Xbox glyphs for every pad; add a DualSense identity (054c:0ce6) when a game needs PlayStation glyphs.
//
// Report 1, 18 bytes including the id: u16 LX LY RX RY (0..65535, Y grows downward), u16 LT RT (0..1023, 10 bits),
// u8 hat (1..8 clockwise from north, 0 = centered), u32 buttons: bit n = HID button n+1 (A1 B2 X4 Y5 LB7 RB8 Menu12
// LS14 RS15), bit 16 = View (Consumer AC Back). Elements are generated from the same bit table, so element values,
// queues, value callbacks and raw reports always agree.
//
// Set SHACK_HID_GAMEPAD=0 for a guest that reads GameController itself (the loader does this for Unreal Engine),
// otherwise the same pad would arrive twice.
//
// SHACK_HID_PAD=xbox2016 (the loader sets it for Rewired games): the same pad on its 2016 Bluetooth firmware
// (045e:02e0), where View is HID button 17 and Guide button 16 instead of Consumer AC Back; the report bytes are the
// same. Rewired before 2019 (Cuphead) knows only that one on macOS and maps 02fd as an unknown controller (up/down
// swapped, buttons guessed); every Rewired keeps the old entry.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <math.h>

typedef int32_t IOReturn;
enum { kSuccess = 0, kUnsupported = (int32_t)0xE00002C7 };
enum { kTypeMisc = 1, kTypeButton = 2, kTypeCollection = 513 };
typedef void (*DeviceCB)(void *ctx, IOReturn r, void *sender, void *device);
typedef void (*ReportCB)(void *ctx, IOReturn r, void *sender, uint32_t type, uint32_t reportID, uint8_t *report, CFIndex len);
typedef void (*ReportTimeCB)(void *ctx, IOReturn r, void *sender, uint32_t type, uint32_t reportID, uint8_t *report, CFIndex len, uint64_t ts);
typedef void (*ValueCB)(void *ctx, IOReturn r, void *sender, void *value);
typedef void (*CallbackCB)(void *ctx, IOReturn r, void *sender);

#define REPORT_LEN 18
typedef struct { uint16_t page, usage; uint32_t type; int32_t min, max, pmin, pmax; uint8_t bits; uint16_t bit; } Spec;
static const Spec kSpecs[] = {
    {1, 0x30, kTypeMisc, 0, 65535, 0, 65535, 16, 8},   {1, 0x31, kTypeMisc, 0, 65535, 0, 65535, 16, 24},
    {1, 0x32, kTypeMisc, 0, 65535, 0, 65535, 16, 40},  {1, 0x35, kTypeMisc, 0, 65535, 0, 65535, 16, 56},
    {2, 0xC5, kTypeMisc, 0, 1023, 0, 1023, 10, 72},    {2, 0xC4, kTypeMisc, 0, 1023, 0, 1023, 10, 88},
    {1, 0x39, kTypeMisc, 1, 8, 0, 315, 4, 104},
    {9, 1, kTypeButton, 0, 1, 0, 1, 1, 112},  {9, 2, kTypeButton, 0, 1, 0, 1, 1, 113},  {9, 3, kTypeButton, 0, 1, 0, 1, 1, 114},
    {9, 4, kTypeButton, 0, 1, 0, 1, 1, 115},  {9, 5, kTypeButton, 0, 1, 0, 1, 1, 116},  {9, 6, kTypeButton, 0, 1, 0, 1, 1, 117},
    {9, 7, kTypeButton, 0, 1, 0, 1, 1, 118},  {9, 8, kTypeButton, 0, 1, 0, 1, 1, 119},  {9, 9, kTypeButton, 0, 1, 0, 1, 1, 120},
    {9, 10, kTypeButton, 0, 1, 0, 1, 1, 121}, {9, 11, kTypeButton, 0, 1, 0, 1, 1, 122}, {9, 12, kTypeButton, 0, 1, 0, 1, 1, 123},
    {9, 13, kTypeButton, 0, 1, 0, 1, 1, 124}, {9, 14, kTypeButton, 0, 1, 0, 1, 1, 125}, {9, 15, kTypeButton, 0, 1, 0, 1, 1, 126},
    {0x0C, 0x224, kTypeButton, 0, 1, 0, 1, 1, 128},
};
#define NSPECS (sizeof kSpecs / sizeof *kSpecs)
static const Spec kSpecs2016[] = { {9, 16, kTypeButton, 0, 1, 0, 1, 1, 127}, {9, 17, kTypeButton, 0, 1, 0, 1, 1, 128} };   // Guide, View
// The HID report descriptor for the same report (some stacks parse it instead of walking elements).
static const uint8_t kDescriptor[] = {
    0x05,0x01, 0x09,0x05, 0xA1,0x01, 0x85,0x01,
    0x09,0x01, 0xA1,0x00, 0x09,0x30, 0x09,0x31, 0x15,0x00, 0x27,0xFF,0xFF,0x00,0x00, 0x95,0x02, 0x75,0x10, 0x81,0x02, 0xC0,
    0x09,0x01, 0xA1,0x00, 0x09,0x32, 0x09,0x35, 0x15,0x00, 0x27,0xFF,0xFF,0x00,0x00, 0x95,0x02, 0x75,0x10, 0x81,0x02, 0xC0,
    0x05,0x02, 0x09,0xC5, 0x15,0x00, 0x26,0xFF,0x03, 0x95,0x01, 0x75,0x0A, 0x81,0x02, 0x25,0x00, 0x75,0x06, 0x81,0x03,
    0x09,0xC4, 0x26,0xFF,0x03, 0x75,0x0A, 0x81,0x02, 0x25,0x00, 0x75,0x06, 0x81,0x03,
    0x05,0x01, 0x09,0x39, 0x15,0x01, 0x25,0x08, 0x35,0x00, 0x46,0x3B,0x01, 0x66,0x14,0x00, 0x75,0x04, 0x95,0x01, 0x81,0x42,
    0x15,0x00, 0x25,0x00, 0x35,0x00, 0x45,0x00, 0x65,0x00, 0x75,0x04, 0x81,0x03,
};
static const uint8_t kButtons2019[] = {   // buttons 1-15, a pad bit, Consumer AC Back (View), 15 pad bits
    0x05,0x09, 0x19,0x01, 0x29,0x0F, 0x25,0x01, 0x75,0x01, 0x95,0x0F, 0x81,0x02, 0x25,0x00, 0x95,0x01, 0x81,0x03,
    0x05,0x0C, 0x0A,0x24,0x02, 0x25,0x01, 0x81,0x02, 0x25,0x00, 0x95,0x0F, 0x81,0x03,
    0xC0,
};
static const uint8_t kButtons2016[] = {   // buttons 1-17 (16 Guide, 17 View), 15 pad bits
    0x05,0x09, 0x19,0x01, 0x29,0x11, 0x25,0x01, 0x75,0x01, 0x95,0x11, 0x81,0x02, 0x25,0x00, 0x95,0x0F, 0x81,0x03,
    0xC0,
};

// ---- pad state -> report -------------------------------------------------------------------------------------
typedef struct { float lx, ly, rx, ry, lt, rt; BOOL up, down, left, right; uint32_t buttons; } PadInput;   // buttons: report bits
enum { kA = 1 << 0, kB = 1 << 1, kX = 1 << 3, kY = 1 << 4, kLB = 1 << 6, kRB = 1 << 7, kMenu = 1 << 11, kLS = 1 << 13, kRS = 1 << 14, kView = 1 << 16 };

static void Put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static uint16_t Axis(float v) { return (uint16_t)lrintf(fminf(fmaxf((v + 1) * 32767.5f, 0), 65535)); }
static void Encode(const PadInput *in, uint8_t r[REPORT_LEN]) {
    memset(r, 0, REPORT_LEN); r[0] = 1;
    Put16(r + 1, Axis(in->lx)); Put16(r + 3, Axis(-in->ly)); Put16(r + 5, Axis(in->rx)); Put16(r + 7, Axis(-in->ry));   // GC y is up
    Put16(r + 9, (uint16_t)lrintf(fminf(fmaxf(in->lt, 0), 1) * 1023)); Put16(r + 11, (uint16_t)lrintf(fminf(fmaxf(in->rt, 0), 1) * 1023));
    int dx = in->right - in->left, dy = in->up - in->down;   // hat 1..8 clockwise from north
    static const uint8_t hat[3][3] = { {8, 7, 6}, {1, 0, 5}, {2, 3, 4} };   // [dx + 1][1 - dy]: rows left..right, columns up..down
    r[13] = hat[dx + 1][1 - dy];
    r[14] = in->buttons; r[15] = in->buttons >> 8; r[16] = in->buttons >> 16; r[17] = in->buttons >> 24;
}
static int32_t Extract(const uint8_t *r, const Spec *s) {
    uint32_t v = 0;
    for (int i = 0; i < s->bits; i++) { int b = s->bit + i; v |= (uint32_t)((r[b >> 3] >> (b & 7)) & 1) << i; }
    return (int32_t)v;
}

// ---- objects ---------------------------------------------------------------------------------------------------
static void *IOKitLib(void) { static void *h; if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW); return h; }
// Real IOKit type ids, so `CFGetTypeID(x) == IOHIDElementGetTypeID()` style checks hold for our objects.
static CFTypeID RealTypeID(const char *fn) { CFTypeID (*f)(void) = dlsym(IOKitLib(), fn); return f ? f() : 0; }
#define TYPEID(fn) - (CFTypeID)_cfTypeID { static CFTypeID t; if (!t) t = RealTypeID(fn); return t; }

@class SHDevice;
@interface SHElement : NSObject { @public const Spec *spec; uint32_t cookie, type; __unsafe_unretained SHDevice *device; __unsafe_unretained SHElement *parent; NSArray *children; id lastValue; }
@end
@implementation SHElement TYPEID("IOHIDElementGetTypeID") @end

@interface SHValue : NSObject { @public SHElement *element; CFIndex integer; uint64_t time; }
@end
@implementation SHValue TYPEID("IOHIDValueGetTypeID") @end

// Each guest has its own callbacks on a pad, as each Mac process has its own IOHIDDevice objects: the Steam client and a
// game it started both register on the same pad, and the game's registration replaced Steam's (Big Picture had no pad
// after the game quit, 2026-10-04). Client 0 is the first guest, 1 a second one (ShackHooksIsSecondCaller).
typedef struct {
    CFRunLoopRef rl; CFStringRef mode;
    ReportCB reportCB; ReportTimeCB reportTimeCB; void *reportCtx; uint8_t *reportBuf; CFIndex reportLen;
    NSUInteger reportGen;   // bumped by every (un)registration and close: queued reports for an old one are dropped
    ValueCB valueCB; void *valueCtx; CallbackCB removalCB; void *removalCtx;
} SHClient;
@interface SHDevice : NSObject {
@public
    GCController *gc; NSMutableDictionary *props; NSArray<SHElement *> *elements; uint8_t report[REPORT_LEN];
    SHClient c[2];
}
@end
@implementation SHDevice TYPEID("IOHIDDeviceGetTypeID") @end

@interface SHManager : NSObject {
@public
    NSArray<NSDictionary *> *matching; BOOL open; CFRunLoopRef rl; CFStringRef mode; NSMutableSet *announced; int client;
    DeviceCB matchCB, removeCB; void *matchCtx, *removeCtx; ValueCB valueCB; void *valueCtx; ReportCB reportCB; void *reportCtx;
    NSMutableDictionary *props;
}
@end
@implementation SHManager TYPEID("IOHIDManagerGetTypeID") @end

@interface SHQueue : NSObject { @public SHDevice *device; NSHashTable *elements; NSMutableArray *pending; CFIndex depth; BOOL started; int client;
    CallbackCB availCB; void *availCtx; CFRunLoopRef rl; CFStringRef mode; }
@end
@implementation SHQueue TYPEID("IOHIDQueueGetTypeID") @end

// ponytail: first 40 lines per call site, enough to see how a guest drives HID; remove once guests are known-good.
#define TRACE(fmt, ...) do { static int n_; if (n_++ < 40) fprintf(stderr, "[ShackHID] " fmt "\n", ##__VA_ARGS__); } while (0)
static const char *LoopName(CFRunLoopRef rl) { return !rl ? "none" : rl == CFRunLoopGetMain() ? "main" : "thread"; }
static const char *Str(CFStringRef s) { static char b[128]; if (!s) return "(null)"; CFStringGetCString(s, b, sizeof b, kCFStringEncodingUTF8); return b; }

static NSRecursiveLock *gLock;
static NSMutableArray<SHDevice *> *gDevices;
static void NotifyWatchers(SHDevice *d, BOOL removed);   // IOServiceAddMatchingNotification callers (IORegistry view)
static NSHashTable<SHManager *> *gManagers;
static NSHashTable<SHQueue *> *gQueues;

// Which guest's code called: 0 the first, 1 a second (a game Steam started). The host hands its test over (a Release
// app exports none of its functions, so a dlsym for it found nothing and every call counted as the first guest's).
static BOOL (*gIsSecond)(const void *pc);
void ShackHIDSetSecondGuestTest(BOOL (*isSecond)(const void *pc)) { gIsSecond = isSecond; }
static int Client(const void *ra) { return gIsSecond && gIsSecond(ra) ? 1 : 0; }
#define CALLER Client(__builtin_return_address(0))
static void Post(CFRunLoopRef rl, CFStringRef mode, dispatch_block_t b) {
    if (!rl) { b(); return; }
    CFRunLoopPerformBlock(rl, mode ?: kCFRunLoopDefaultMode, b); CFRunLoopWakeUp(rl);
}
// Scheduling a real IOHIDManager/device/queue adds a run loop source. Guests rely on that: Unity schedules its manager
// on an input thread and calls CFRunLoopRun(), which returns at once from a loop with no sources (the thread then
// unschedules and ends, and no pad ever arrives). An idle source keeps that loop alive; delivery uses perform blocks.
static void Idle(void *info) {}
static void SetLoop(CFRunLoopRef *rl, CFStringRef *mode, CFRunLoopRef newRL, CFStringRef newMode) {
    static NSMapTable *sources; if (!sources) sources = [NSMapTable strongToStrongObjectsMapTable];   // key: rl/mode pair
    if (*rl) {
        NSString *key = [NSString stringWithFormat:@"%p/%@", *rl, *mode];
        CFRunLoopSourceRef src = (__bridge CFRunLoopSourceRef)[sources objectForKey:key];
        if (src) { CFRunLoopRemoveSource(*rl, src, *mode); [sources removeObjectForKey:key]; }
        CFRelease(*rl); CFRelease(*mode);
    }
    *rl = newRL ? (CFRunLoopRef)CFRetain(newRL) : NULL; *mode = newRL ? CFStringCreateCopy(NULL, newMode ?: kCFRunLoopDefaultMode) : NULL;
    if (*rl) {
        CFRunLoopSourceContext ctx = { .perform = Idle };
        CFRunLoopSourceRef src = CFRunLoopSourceCreate(NULL, 0, &ctx);
        CFRunLoopAddSource(*rl, src, *mode);
        [sources setObject:(__bridge id)src forKey:[NSString stringWithFormat:@"%p/%@", *rl, *mode]]; CFRelease(src);
    }
}
static SHManager *OwnerOf(SHDevice *d, int k) {   // a device inherits the run loop of the client's scheduled manager that announced it
    for (SHManager *m in gManagers) if (m->client == k && m->rl && [m->announced containsObject:d]) return m;
    return nil;
}
static void DeviceLoop(SHDevice *d, int k, CFRunLoopRef *rl, CFStringRef *mode) {
    SHClient *c = &d->c[k]; SHManager *m = c->rl ? nil : OwnerOf(d, k);
    *rl = c->rl ?: (m ? m->rl : NULL); *mode = c->rl ? c->mode : (m ? m->mode : NULL);
}

// Exactly the properties a real IOHIDDevice has, no more: guests probe keys and trust what comes back. Unity's HID
// Utilities read "DeviceUsage" as a 64-bit CFNumber into a 32-bit stack slot; a real device has no such top-level key
// (it lives only inside DeviceUsagePairs), so on a Mac the overflow never happens. Exposing it here clobbered a saved
// register and crashed the first joystick button press.
static BOOL gXbox2016;   // SHACK_HID_PAD=xbox2016 (header)
static SHDevice *NewDevice(GCController *gc, uint32_t index) {
    SHDevice *d = [SHDevice new]; d->gc = gc;
    PadInput idle = {0}; Encode(&idle, d->report);
    NSString *serial = [NSString stringWithFormat:@"shack-%u", index];
    NSMutableData *descriptor = [NSMutableData dataWithBytes:kDescriptor length:sizeof kDescriptor];
    if (gXbox2016) [descriptor appendBytes:kButtons2016 length:sizeof kButtons2016]; else [descriptor appendBytes:kButtons2019 length:sizeof kButtons2019];
    d->props = [@{ @"Transport": @"Bluetooth", @"VendorID": @0x045E, @"ProductID": gXbox2016 ? @0x02E0 : @0x02FD, @"VersionNumber": @0x0903,
        @"Manufacturer": @"Microsoft", @"Product": @"Xbox Wireless Controller", @"SerialNumber": serial,
        @"PrimaryUsagePage": @1, @"PrimaryUsage": @5, @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @1, @"DeviceUsage": @5}],
        @"MaxInputReportSize": @REPORT_LEN, @"MaxOutputReportSize": @9, @"MaxFeatureReportSize": @0,
        @"LocationID": @(0x5348 << 16 | index), @"ReportInterval": @8000, @"CountryCode": @0,
        @"ReportDescriptor": descriptor, @"PhysicalDeviceUniqueID": serial } mutableCopy];
    SHElement *app = [SHElement new]; app->type = kTypeCollection; app->cookie = 1; app->device = d;
    NSMutableArray *all = [NSMutableArray arrayWithObject:app], *kids = [NSMutableArray array];
    NSMutableArray<NSValue *> *specs = [NSMutableArray array];
    for (uint32_t i = 0; i < NSPECS; i++) if (!gXbox2016 || kSpecs[i].page != 0x0C) [specs addObject:[NSValue valueWithPointer:&kSpecs[i]]];
    if (gXbox2016) for (size_t i = 0; i < sizeof kSpecs2016 / sizeof *kSpecs2016; i++) [specs addObject:[NSValue valueWithPointer:&kSpecs2016[i]]];
    for (NSValue *v in specs) {
        const Spec *s = v.pointerValue;
        SHElement *e = [SHElement new]; e->spec = s; e->type = s->type; e->cookie = (uint32_t)all.count + 1; e->device = d; e->parent = app;
        [kids addObject:e]; [all addObject:e];
    }
    app->children = kids; d->elements = all;
    return d;
}
// IOKit matching: every key equals the device property, except DeviceUsagePage/DeviceUsage, which match any entry of
// DeviceUsagePairs (a usage page alone matches any pair on that page).
static BOOL Matches(SHDevice *d, NSArray<NSDictionary *> *matching) {
    if (!matching) return YES;
    for (NSDictionary *m in matching) {
        BOOL ok = YES;
        for (NSString *k in m) {
            if ([k isEqualToString:@"DeviceUsagePage"] || [k isEqualToString:@"DeviceUsage"]) continue;
            if (![d->props[k] isEqual:m[k]]) { ok = NO; break; }
        }
        if (ok && (m[@"DeviceUsagePage"] || m[@"DeviceUsage"])) {
            BOOL pair = NO;
            for (NSDictionary *u in d->props[@"DeviceUsagePairs"])
                pair |= (!m[@"DeviceUsagePage"] || [u[@"DeviceUsagePage"] isEqual:m[@"DeviceUsagePage"]]) && (!m[@"DeviceUsage"] || [u[@"DeviceUsage"] isEqual:m[@"DeviceUsage"]]);
            ok = pair;
        }
        if (ok) return YES;
    }
    return NO;
}
static void Announce(SHManager *m) {
    if (!m->open || !m->matchCB || !m->rl) return;   // like IOKit: matching callbacks need an open, scheduled manager
    for (SHDevice *d in gDevices) {
        if ([m->announced containsObject:d] || !Matches(d, m->matching)) continue;
        [m->announced addObject:d];
        DeviceCB cb = m->matchCB; void *ctx = m->matchCtx;
        TRACE("announce device %p to manager %p on %s loop", d, m, LoopName(m->rl));
        Post(m->rl, m->mode, ^{ TRACE("matching callback running for %p", d); cb(ctx, kSuccess, (__bridge void *)m, (__bridge void *)d); });
    }
}

static SHValue *NewValue(SHElement *e, CFIndex v, uint64_t t) { SHValue *x = [SHValue new]; x->element = e; x->integer = v; x->time = t; return x; }
static SHValue *CurrentValue(SHElement *e) {
    CFIndex v = e->spec ? Extract(e->device->report, e->spec) : 0;
    SHValue *x = e->lastValue;
    if (!x || x->integer != v) { x = NewValue(e, v, mach_absolute_time()); e->lastValue = x; }
    return x;
}

// The report buffer belongs to the game, which frees it after unregistering or closing (SDL's HIDAPI opens, closes
// and reopens a pad at startup): a report queued for an older registration must not be written into it (that heap
// corruption crashed Shovel Knight inside later host mallocs).
static BOOL CopyIfCurrent(SHDevice *d, int k, NSUInteger gen, uint8_t *buf, NSData *copy, CFIndex n) {
    [gLock lock];
    BOOL live = d->c[k].reportGen == gen && d->c[k].reportBuf == buf;
    if (live) memcpy(buf, copy.bytes, (size_t)n);
    [gLock unlock];
    return live;
}

// A new report: raw report callbacks, per-element value callbacks, queues. Called with gLock held.
static void Deliver(SHDevice *d, const uint8_t *next) {
    uint8_t old[REPORT_LEN]; memcpy(old, d->report, REPORT_LEN); memcpy(d->report, next, REPORT_LEN);
    uint64_t now = mach_absolute_time();
    for (int k = 0; k < 2; k++) {
        SHClient *c = &d->c[k];
        if (!(c->reportCB || c->reportTimeCB) || !c->reportBuf) continue;
        CFRunLoopRef rl; CFStringRef mode; DeviceLoop(d, k, &rl, &mode);
        ReportCB cb = c->reportCB; ReportTimeCB tcb = c->reportTimeCB; void *ctx = c->reportCtx; uint8_t *buf = c->reportBuf;
        CFIndex n = MIN(c->reportLen, REPORT_LEN); NSData *copy = [NSData dataWithBytes:next length:REPORT_LEN]; NSUInteger gen = c->reportGen;
        Post(rl, mode, ^{
            if (!CopyIfCurrent(d, k, gen, buf, copy, n)) return;
            static uint8_t seen[5];   // diagnostic: hat/button changes a client's report callback really got, when, how late
            static int changes;
            if (n >= 18 && memcmp(seen, buf + 13, 5) && changes++ < 400) {
                memcpy(seen, buf + 13, 5);
                time_t t = time(NULL); char hms[16]; strftime(hms, sizeof hms, "%H:%M:%S", localtime(&t));
                mach_timebase_info_data_t tb; mach_timebase_info(&tb);
                fprintf(stderr, "[ShackHID] %s report to %p after %.1f ms: hat %u buttons %02x %02x %02x %02x\n", hms, d,
                        (double)(mach_absolute_time() - now) * tb.numer / tb.denom / 1e6, buf[13], buf[14], buf[15], buf[16], buf[17]);
            }
            if (cb) cb(ctx, kSuccess, (__bridge void *)d, 0 /* input */, 1, buf, n); else tcb(ctx, kSuccess, (__bridge void *)d, 0, 1, buf, n, now);
        });
    }
    for (SHManager *m in gManagers) if (m->reportCB && [m->announced containsObject:d]) {
        ReportCB cb = m->reportCB; void *ctx = m->reportCtx; NSMutableData *copy = [NSMutableData dataWithBytes:next length:REPORT_LEN];
        Post(m->rl, m->mode, ^{ cb(ctx, kSuccess, (__bridge void *)d, 0, 1, copy.mutableBytes, REPORT_LEN); });
    }
    for (SHElement *e in d->elements) {
        if (!e->spec || Extract(old, e->spec) == Extract(next, e->spec)) continue;
        SHValue *v = NewValue(e, Extract(next, e->spec), now); e->lastValue = v;
        for (int k = 0; k < 2; k++) if (d->c[k].valueCB) {
            CFRunLoopRef rl; CFStringRef mode; DeviceLoop(d, k, &rl, &mode);
            ValueCB cb = d->c[k].valueCB; void *ctx = d->c[k].valueCtx; Post(rl, mode, ^{ cb(ctx, kSuccess, (__bridge void *)d, (__bridge void *)v); });
        }
        for (SHManager *m in gManagers) if (m->valueCB && [m->announced containsObject:d]) {
            ValueCB cb = m->valueCB; void *ctx = m->valueCtx; Post(m->rl, m->mode, ^{ cb(ctx, kSuccess, (__bridge void *)m, (__bridge void *)v); });
        }
        for (SHQueue *q in gQueues) {
            if (q->device != d || !q->started || ![q->elements containsObject:e]) continue;
            if ((CFIndex)q->pending.count >= q->depth) { TRACE("queue %p full (depth %ld): dropped its oldest value", q, (long)q->depth); [q->pending removeObjectAtIndex:0]; }
            [q->pending addObject:v];
            if (q->availCB) { CallbackCB cb = q->availCB; void *ctx = q->availCtx; Post(q->rl, q->mode, ^{ cb(ctx, kSuccess, (__bridge void *)q); }); }
        }
    }
}

// The current report once to a newly registered report callback (a real pad reports continuously).
static void ResendReport(SHDevice *d, int k) {
    SHClient *c = &d->c[k];
    if (!(c->reportCB || c->reportTimeCB) || !c->reportBuf) return;
    CFRunLoopRef rl; CFStringRef mode; DeviceLoop(d, k, &rl, &mode);
    ReportCB cb = c->reportCB; ReportTimeCB tcb = c->reportTimeCB; void *ctx = c->reportCtx; uint8_t *buf = c->reportBuf;
    CFIndex n = MIN(c->reportLen, REPORT_LEN); NSData *copy = [NSData dataWithBytes:d->report length:REPORT_LEN]; uint64_t now = mach_absolute_time();
    NSUInteger gen = c->reportGen;
    Post(rl, mode, ^{
        if (!CopyIfCurrent(d, k, gen, buf, copy, n)) return;
        if (cb) cb(ctx, kSuccess, (__bridge void *)d, 0, 1, buf, n); else tcb(ctx, kSuccess, (__bridge void *)d, 0, 1, buf, n, now);
    });
}

// ---- GameController source ---------------------------------------------------------------------------------------
static BOOL Pressed(GCControllerButtonInput *b) { return b.isPressed; }
static void Read(GCExtendedGamepad *g, PadInput *in) {
    *in = (PadInput){ g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value,
        g.leftTrigger.value, g.rightTrigger.value, Pressed(g.dpad.up), Pressed(g.dpad.down), Pressed(g.dpad.left), Pressed(g.dpad.right), 0 };
    in->buttons = (Pressed(g.buttonA) ? kA : 0) | (Pressed(g.buttonB) ? kB : 0) | (Pressed(g.buttonX) ? kX : 0) | (Pressed(g.buttonY) ? kY : 0)
        | (Pressed(g.leftShoulder) ? kLB : 0) | (Pressed(g.rightShoulder) ? kRB : 0) | (Pressed(g.buttonMenu) ? kMenu : 0)
        | (Pressed(g.leftThumbstickButton) ? kLS : 0) | (Pressed(g.rightThumbstickButton) ? kRS : 0) | (Pressed(g.buttonOptions) ? kView : 0);
}
// The pads' 125 Hz poll (Start) runs only while there is a pad to read: no wakeups otherwise. With gLock held.
static dispatch_source_t gPoll; static BOOL gPolling;
static void PollWhilePads(void) {
    BOOL want = gDevices.count > 0;
    if (!gPoll || want == gPolling) return;
    gPolling = want;
    if (want) dispatch_resume(gPoll); else dispatch_suspend(gPoll);
}
static void Attach(GCController *gc) {
    [gLock lock];
    BOOL known = NO; for (SHDevice *d in gDevices) known |= d->gc == gc;
    if (!known && gc.extendedGamepad) {
        static uint32_t n; SHDevice *d = NewDevice(gc, ++n); [gDevices addObject:d];
        fprintf(stderr, "[ShackHID] %s (%s) -> virtual Xbox Wireless Controller (045e:%s) #%u\n", gc.vendorName.UTF8String ?: "pad", gc.productCategory.UTF8String ?: "", gXbox2016 ? "02e0" : "02fd", n);
        fprintf(stderr, "[ShackHID] %lu manager(s)\n", (unsigned long)gManagers.allObjects.count);
        for (SHManager *m in gManagers) {
            fprintf(stderr, "[ShackHID]   manager %p open=%d callback=%d loop=%s matches=%d\n", m, m->open, m->matchCB != NULL, LoopName(m->rl), Matches(d, m->matching));
            Announce(m);
        }
        NotifyWatchers(d, NO);
    }
    PollWhilePads();
    [gLock unlock];
}
static void Detach(GCController *gc) {
    [gLock lock];
    for (SHDevice *d in [gDevices copy]) {
        if (d->gc != gc) continue;
        for (int k = 0; k < 2; k++) if (d->c[k].removalCB) {
            CFRunLoopRef rl; CFStringRef mode; DeviceLoop(d, k, &rl, &mode);
            CallbackCB cb = d->c[k].removalCB; void *ctx = d->c[k].removalCtx; Post(rl, mode, ^{ cb(ctx, kSuccess, (__bridge void *)d); });
        }
        for (SHManager *m in gManagers) if ([m->announced containsObject:d]) {
            [m->announced removeObject:d];
            if (m->removeCB) { DeviceCB cb = m->removeCB; void *ctx = m->removeCtx; Post(m->rl, m->mode, ^{ cb(ctx, kSuccess, (__bridge void *)m, (__bridge void *)d); }); }
        }
        [gDevices removeObject:d];
        NotifyWatchers(d, YES);
    }
    PollWhilePads();
    [gLock unlock];
}
static BOOL gPadsOff;   // SHACK_HID_GAMEPAD=0 (Unreal reads GameController itself)
static BOOL gTap;       // SHACK_HID_TAP=1 (diagnostics): every pad taps D-pad right for 0.3 s every 3 s, a padless phone gets one
static void Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSRecursiveLock new]; gDevices = [NSMutableArray array];
        gManagers = [NSHashTable weakObjectsHashTable];
        // ponytail: queues are never freed. Rewired stops and releases one, and a timer polls it once more; a Mac's queue
        // still reads empty then, ours must not be freed memory. A queue is a few hundred bytes; add a purge if a game churns them.
        gQueues = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        // +[GCController supportsHIDDevice:] (SDL2 and others ask it to avoid duplicate pads) would hand our object to
        // real IOKit inside GameController. Our pads are GameController pads, so the true answer is YES: the caller
        // then reads that pad through GameController and skips the HID copy.
        // iOS has no such method at all (macOS 11+ only); guests reach it because @available(macOS 11) answers yes.
        Class gcMeta = object_getClass(NSClassFromString(@"GCController"));
        SEL supSel = NSSelectorFromString(@"supportsHIDDevice:");
        Method sup = gcMeta ? class_getInstanceMethod(gcMeta, supSel) : NULL;
        if (sup) {
            BOOL (*orig)(id, SEL, id) = (void *)method_getImplementation(sup);
            method_setImplementation(sup, imp_implementationWithBlock(^BOOL(id cls, id dev) {
                return [dev isKindOfClass:SHDevice.class] ? YES : orig(cls, supSel, dev);
            }));
        } else if (gcMeta) {
            class_addMethod(gcMeta, supSel, imp_implementationWithBlock(^BOOL(id cls, id dev) { return [dev isKindOfClass:SHDevice.class]; }), "B@:@");
        }
        const char *pad = getenv("SHACK_HID_PAD");
        gXbox2016 = pad && !strcmp(pad, "xbox2016");
        gTap = getenv("SHACK_HID_TAP") != NULL;
        const char *env = getenv("SHACK_HID_GAMEPAD");
        if (env && !strcmp(env, "0")) { gPadsOff = YES; fprintf(stderr, "[ShackHID] virtual gamepads off (SHACK_HID_GAMEPAD=0)\n"); return; }
#ifdef SHACK_HID_TEST
        return;   // the Mac test drives pads itself; a real pad on the Mac must not join in
#endif
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { Attach(n.object); }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { Detach(n.object); }];
        dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) Attach(c); });
        if (gTap) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [gLock lock];
            if (!gDevices.count) { SHDevice *d = NewDevice(nil, 99); [gDevices addObject:d]; for (SHManager *m in gManagers) Announce(m); NotifyWatchers(d, NO); }
            PollWhilePads();
            fprintf(stderr, "[ShackHID] SHACK_HID_TAP: tapping D-pad right on %lu pad(s)\n", (unsigned long)gDevices.count);
            [gLock unlock];
        });
        // Poll at the Xbox pad's own 125 Hz report rate. Polling, not valueChangedHandler: a guest that also uses
        // GameController would replace (or have replaced) a handler on the same GCController object.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("shack.hid", DISPATCH_QUEUE_SERIAL));
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            [gLock lock];
            BOOL tap = gTap && fmod(CFAbsoluteTimeGetCurrent(), 3) < 0.3;
            for (SHDevice *d in gDevices) {
                PadInput in; Read(d->gc.extendedGamepad, &in); in.right |= tap;
                uint8_t r[REPORT_LEN]; Encode(&in, r);
                if (memcmp(r, d->report, REPORT_LEN)) Deliver(d, r);
            }
            [gLock unlock];
        });
        [gLock lock]; gPoll = timer; PollWhilePads(); [gLock unlock];   // created suspended
    });
}

#define OBJ(T, x) ((__bridge T *)(x))
#define LOCKED(...) ({ [gLock lock]; __typeof__(({ __VA_ARGS__; })) r_ = ({ __VA_ARGS__; }); [gLock unlock]; r_; })   // typeof does not evaluate

// ---- IOHIDManager ------------------------------------------------------------------------------------------------
CFTypeID IOHIDManagerGetTypeID(void) { return RealTypeID("IOHIDManagerGetTypeID"); }
void *IOHIDManagerCreate(CFAllocatorRef a, uint32_t options) {
    Start();
    SHManager *m = [SHManager new]; m->announced = [NSMutableSet set]; m->props = [NSMutableDictionary dictionary]; m->client = CALLER;
    TRACE("IOHIDManagerCreate -> %p (thread %s)", m, NSThread.isMainThread ? "main" : "other");
    [gLock lock]; [gManagers addObject:m]; [gLock unlock];
    return (void *)CFBridgingRetain(m);
}
IOReturn IOHIDManagerOpen(void *mgr, uint32_t options) { SHManager *m = OBJ(SHManager, mgr); TRACE("IOHIDManagerOpen %p", m); [gLock lock]; m->open = YES; Announce(m); [gLock unlock]; return kSuccess; }
IOReturn IOHIDManagerClose(void *mgr, uint32_t options) { SHManager *m = OBJ(SHManager, mgr); TRACE("IOHIDManagerClose %p", m); [gLock lock]; m->open = NO; [gLock unlock]; return kSuccess; }
CFTypeRef IOHIDManagerGetProperty(void *mgr, CFStringRef key) { return (__bridge CFTypeRef)LOCKED(OBJ(SHManager, mgr)->props[(__bridge NSString *)key]); }
Boolean IOHIDManagerSetProperty(void *mgr, CFStringRef key, CFTypeRef v) { [gLock lock]; OBJ(SHManager, mgr)->props[(__bridge NSString *)key] = (__bridge id)v; [gLock unlock]; return true; }
void IOHIDManagerSetDeviceMatching(void *mgr, CFDictionaryRef d) {
    SHManager *m = OBJ(SHManager, mgr); TRACE("SetDeviceMatching %p %s", m, [[(__bridge NSDictionary *)d description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
    [gLock lock]; m->matching = d ? @[(__bridge NSDictionary *)d] : nil; Announce(m); [gLock unlock];
}
void IOHIDManagerSetDeviceMatchingMultiple(void *mgr, CFArrayRef a) {
    SHManager *m = OBJ(SHManager, mgr); TRACE("SetDeviceMatchingMultiple %p %s", m, [[(__bridge NSArray *)a description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
    [gLock lock]; m->matching = a ? [(__bridge NSArray *)a copy] : nil; Announce(m); [gLock unlock];
}
CFSetRef IOHIDManagerCopyDevices(void *mgr) {
    SHManager *m = OBJ(SHManager, mgr); NSMutableSet *s = [NSMutableSet set];
    [gLock lock]; for (SHDevice *d in gDevices) if (Matches(d, m->matching)) [s addObject:d]; [gLock unlock];
    TRACE("CopyDevices %p -> %lu", m, (unsigned long)s.count);
    return s.count ? (CFSetRef)CFBridgingRetain(s) : NULL;
}
void IOHIDManagerRegisterDeviceMatchingCallback(void *mgr, DeviceCB cb, void *ctx) {
    SHManager *m = OBJ(SHManager, mgr); TRACE("RegisterDeviceMatchingCallback %p", m); [gLock lock]; m->matchCB = cb; m->matchCtx = ctx; Announce(m); [gLock unlock];
}
void IOHIDManagerRegisterDeviceRemovalCallback(void *mgr, DeviceCB cb, void *ctx) { SHManager *m = OBJ(SHManager, mgr); [gLock lock]; m->removeCB = cb; m->removeCtx = ctx; [gLock unlock]; }
void IOHIDManagerRegisterInputValueCallback(void *mgr, ValueCB cb, void *ctx) { SHManager *m = OBJ(SHManager, mgr); [gLock lock]; m->valueCB = cb; m->valueCtx = ctx; [gLock unlock]; }
void IOHIDManagerRegisterInputReportCallback(void *mgr, ReportCB cb, void *ctx) { SHManager *m = OBJ(SHManager, mgr); [gLock lock]; m->reportCB = cb; m->reportCtx = ctx; [gLock unlock]; }
void IOHIDManagerSetInputValueMatching(void *mgr, CFDictionaryRef d) {}          // ponytail: every value reaches the callback
void IOHIDManagerSetInputValueMatchingMultiple(void *mgr, CFArrayRef a) {}
void IOHIDManagerScheduleWithRunLoop(void *mgr, CFRunLoopRef rl, CFStringRef mode) {
    SHManager *m = OBJ(SHManager, mgr); TRACE("ScheduleWithRunLoop %p %s loop, mode %s", m, LoopName(rl), Str(mode));
    [gLock lock]; SetLoop(&m->rl, &m->mode, rl, mode); Announce(m); [gLock unlock];
}
void IOHIDManagerUnscheduleFromRunLoop(void *mgr, CFRunLoopRef rl, CFStringRef mode) { SHManager *m = OBJ(SHManager, mgr); TRACE("IOHIDManagerUnschedule %p", m); [gLock lock]; SetLoop(&m->rl, &m->mode, NULL, NULL); [gLock unlock]; }

// ---- IORegistry view of the pads ---------------------------------------------------------------------------------
// Rewired (Cuphead) does not keep the device its matching callback gets: it looks the pad up again by its properties
// through IOServiceGetMatchingServices and makes its own with IOHIDDeviceCreate(service). The real registry knows no
// virtual pad, so an IOHIDDevice query answers with the pads, each pad's service being its LocationID (0x5348000N),
// and every other query goes to IOKit. ponytail: real port names never reach 0x5348xxxx/0x5349xxxx in practice.
static void *RealIOKit(const char *name) { return dlsym(IOKitLib(), name); }
static BOOL IsPadService(uint32_t o) { return o >> 16 == 0x5348; }
static BOOL IsPadIterator(uint32_t o) { return o >> 16 == 0x5349; }
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *gIterators;   // iterator -> services left
static SHDevice *PadForService(uint32_t s) { for (SHDevice *d in gDevices) if ([d->props[@"LocationID"] unsignedIntValue] == s) return d; return nil; }

static NSDictionary *PadMatch(NSDictionary *m) {   // an IOHIDDevice matching dictionary as device properties to compare
    NSMutableDictionary *props = [m mutableCopy]; [props removeObjectForKey:@"IOProviderClass"];
    if ([m[@"IOPropertyMatch"] isKindOfClass:NSDictionary.class]) { [props removeObjectForKey:@"IOPropertyMatch"]; [props addEntriesFromDictionary:m[@"IOPropertyMatch"]]; }
    return props;
}
static uint32_t NewIterator(NSArray<NSNumber *> *services) {   // gLock held
    static uint32_t n; uint32_t it = 0x53490000 | (++n & 0xFFFF);
    if (!gIterators) gIterators = [NSMutableDictionary dictionary];
    gIterators[@(it)] = [services mutableCopy];
    return it;
}

int IOServiceGetMatchingServices(uint32_t port, CFDictionaryRef matching, uint32_t *existing) {
    NSDictionary *m = (__bridge NSDictionary *)matching;
    if (![m[@"IOProviderClass"] isEqual:@"IOHIDDevice"])
        return ((int (*)(uint32_t, CFDictionaryRef, uint32_t *))RealIOKit("IOServiceGetMatchingServices"))(port, matching, existing);
    NSDictionary *props = PadMatch(m);
    Start(); [gLock lock];
    NSMutableArray *found = [NSMutableArray array];
    for (SHDevice *d in gDevices) if (Matches(d, @[props])) [found addObject:d->props[@"LocationID"]];
    uint32_t it = NewIterator(found);
    [gLock unlock];
    TRACE("GetMatchingServices %s -> %lu pad(s)", [[props description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String, (unsigned long)found.count);
    CFRelease(matching);   // like IOKit, the call consumes one reference
    if (existing) *existing = it;
    return 0;
}
uint32_t IOIteratorNext(uint32_t it) {
    if (!IsPadIterator(it)) return ((uint32_t (*)(uint32_t))RealIOKit("IOIteratorNext"))(it);
    [gLock lock]; NSMutableArray *left = gIterators[@(it)]; NSNumber *s = left.firstObject; if (s) [left removeObjectAtIndex:0]; [gLock unlock];
    return s.unsignedIntValue;
}
// SDL's HIDAPI asks IOKit to be told when an IOHIDDevice appears or goes, and rescans only when its callback drains an
// entry from the iterator it is handed (Mina the Hollower, SDL 2.28: `while (IOIteratorNext(it)) changes++`), so an
// empty "look again" did nothing and a pad connected mid-game (the on-screen controller) never reached it. The pads are
// not in IOKit's registry: ShackHID tells those watchers itself, each with an iterator holding the pad's service.
// ponytail: called back on the main queue, not through the guest's notification port; fine for a counter-bumping callback.
typedef void (*MatchingCB)(void *refcon, uint32_t iterator);
@interface SHWatcher : NSObject { @public NSDictionary *props; BOOL removals; MatchingCB cb; void *refcon; int client; }
@end
@implementation SHWatcher
@end
static NSMutableArray<SHWatcher *> *gWatchers;

int IOServiceAddMatchingNotification(struct IONotificationPort *port, const char *type, CFDictionaryRef matching, MatchingCB cb, void *refcon, uint32_t *iterator) {
    NSDictionary *m = (__bridge NSDictionary *)matching; SHWatcher *w = nil;
    if (cb && type && [m[@"IOProviderClass"] isEqual:@"IOHIDDevice"]) {   // before the real call consumes `matching`
        w = [SHWatcher new]; w->props = PadMatch(m); w->removals = !strcmp(type, "IOServiceTerminate"); w->cb = cb; w->refcon = refcon; w->client = CALLER;
    }
    int r = ((int (*)(struct IONotificationPort *, const char *, CFDictionaryRef, MatchingCB, void *, uint32_t *))RealIOKit("IOServiceAddMatchingNotification"))(port, type, matching, cb, refcon, iterator);
    if (w && r == 0) { Start(); [gLock lock]; if (!gWatchers) gWatchers = [NSMutableArray array]; [gWatchers addObject:w]; [gLock unlock]; }
    return r;
}
// ponytail: a notification's iterator stays in gIterators (IOKit owns it, so the guest never releases it): bytes per pad change.
static void NotifyWatchers(SHDevice *d, BOOL removed) {   // gLock held
    unsigned told = 0;
    for (SHWatcher *w in gWatchers) {
        if (w->removals != removed || !Matches(d, @[w->props])) continue;
        MatchingCB cb = w->cb; void *refcon = w->refcon; uint32_t it = NewIterator(@[d->props[@"LocationID"]]);
        dispatch_async(dispatch_get_main_queue(), ^{ cb(refcon, it); });
        told++;
    }
    if (told) fprintf(stderr, "[ShackHID] told %u HID watcher(s) the pad %s\n", told, removed ? "left" : "arrived");
}
// Feral's IndirectX (BioShock) reads a matched pad's properties, then asks for an IOKit plug-in (refused for x86 guests
// in ShackHooks.m) and skips the pad; it gets it through IOHIDManager instead. A failed read has no path in Feral: it
// calls its record's empty removal-callback slot. A pad that has gone meanwhile still answers, with no properties.
int IORegistryEntryCreateCFProperties(uint32_t e, CFMutableDictionaryRef *props, CFAllocatorRef a, uint32_t options) {
    if (!IsPadService(e)) return ((int (*)(uint32_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t))RealIOKit("IORegistryEntryCreateCFProperties"))(e, props, a, options);
    [gLock lock]; NSMutableDictionary *p = [PadForService(e)->props mutableCopy] ?: [NSMutableDictionary dictionary]; [gLock unlock];
    *props = (CFMutableDictionaryRef)CFBridgingRetain(p);
    return 0;
}
int IOObjectRetain(uint32_t o) { return IsPadService(o) || IsPadIterator(o) ? 0 : ((int (*)(uint32_t))RealIOKit("IOObjectRetain"))(o); }
int IOObjectRelease(uint32_t o) {
    if (IsPadIterator(o)) { [gLock lock]; [gIterators removeObjectForKey:@(o)]; [gLock unlock]; return 0; }
    return IsPadService(o) ? 0 : ((int (*)(uint32_t))RealIOKit("IOObjectRelease"))(o);
}

// SDL's hidapi (Steam's SDL3, whose HIDAPI driver takes Xbox pads) opens a pad by registry entry id, "DevSrvsID:<id>":
// IORegistryEntryGetRegistryEntryID of the device's service, later IORegistryEntryIDMatching(id) and
// IOServiceGetMatchingService. A pad's entry id is its service number; any other entry or query goes to IOKit.
int IORegistryEntryGetRegistryEntryID(uint32_t e, uint64_t *entryID) {
    if (!IsPadService(e)) return ((int (*)(uint32_t, uint64_t *))RealIOKit("IORegistryEntryGetRegistryEntryID"))(e, entryID);
    if (entryID) *entryID = e;
    return 0;
}
uint32_t IOServiceGetMatchingService(uint32_t port, CFDictionaryRef matching) {
    NSDictionary *m = (__bridge NSDictionary *)matching;
    NSNumber *entry = [m[@"IORegistryEntryID"] isKindOfClass:NSNumber.class] ? m[@"IORegistryEntryID"] : nil;
    if (entry && entry.unsignedLongLongValue >> 32 == 0 && IsPadService((uint32_t)entry.unsignedLongLongValue)) {
        uint32_t s = (uint32_t)entry.unsignedLongLongValue;
        Start(); [gLock lock]; BOOL present = PadForService(s) != nil; [gLock unlock];
        TRACE("GetMatchingService entry %#x -> %s", s, present ? "pad" : "gone");
        CFRelease(matching);   // like IOKit, the call consumes one reference
        return present ? s : 0;
    }
    if ([m[@"IOProviderClass"] isEqual:@"IOHIDDevice"]) {   // the first pad that matches (consumes `matching` too)
        uint32_t it = 0, s = 0;
        if (IOServiceGetMatchingServices(port, matching, &it) == 0) { s = IOIteratorNext(it); IOObjectRelease(it); }
        return s;
    }
    return ((uint32_t (*)(uint32_t, CFDictionaryRef))RealIOKit("IOServiceGetMatchingService"))(port, matching);
}

// ---- IOHIDDevice ---------------------------------------------------------------------------------------------------
CFTypeID IOHIDDeviceGetTypeID(void) { return RealTypeID("IOHIDDeviceGetTypeID"); }
void *IOHIDDeviceCreate(CFAllocatorRef a, uint32_t service) {   // only a pad's service (IORegistry view above) backs one
    [gLock lock]; SHDevice *d = PadForService(service); [gLock unlock];
    return d ? (void *)CFBridgingRetain(d) : NULL;
}
uint32_t IOHIDDeviceGetService(void *dev) { return [LOCKED(OBJ(SHDevice, dev)->props[@"LocationID"]) unsignedIntValue]; }
IOReturn IOHIDDeviceOpen(void *dev, uint32_t options) { return kSuccess; }
IOReturn IOHIDDeviceClose(void *dev, uint32_t options) {   // a closed device reports nothing; its buffer may be freed next
    SHClient *c = &OBJ(SHDevice, dev)->c[CALLER];
    [gLock lock]; c->reportGen++; c->reportBuf = NULL; c->reportCB = NULL; c->reportTimeCB = NULL; [gLock unlock];
    return kSuccess;
}
Boolean IOHIDDeviceConformsTo(void *dev, uint32_t page, uint32_t usage) { return page == 1 && usage == 5; }
CFTypeRef IOHIDDeviceGetProperty(void *dev, CFStringRef key) { TRACE("DeviceGetProperty %s", Str(key)); return (__bridge CFTypeRef)LOCKED(OBJ(SHDevice, dev)->props[(__bridge NSString *)key]); }
Boolean IOHIDDeviceSetProperty(void *dev, CFStringRef key, CFTypeRef v) { [gLock lock]; OBJ(SHDevice, dev)->props[(__bridge NSString *)key] = (__bridge id)v; [gLock unlock]; return true; }
CFArrayRef IOHIDDeviceCopyMatchingElements(void *dev, CFDictionaryRef matching, uint32_t options) {
    TRACE("CopyMatchingElements %s", matching ? [[(__bridge NSDictionary *)matching description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "all");
    NSDictionary *m = (__bridge NSDictionary *)matching; NSMutableArray *out = [NSMutableArray array];
    for (SHElement *e in OBJ(SHDevice, dev)->elements) {
        uint32_t page = e->spec ? e->spec->page : 1, usage = e->spec ? e->spec->usage : 5;
        if (m[@"UsagePage"] && [m[@"UsagePage"] unsignedIntValue] != page) continue;
        if (m[@"Usage"] && [m[@"Usage"] unsignedIntValue] != usage) continue;
        if (m[@"Type"] && [m[@"Type"] unsignedIntValue] != e->type) continue;
        if (m[@"ElementCookie"] && [m[@"ElementCookie"] unsignedIntValue] != e->cookie) continue;
        [out addObject:e];
    }
    return out.count ? (CFArrayRef)CFBridgingRetain(out) : NULL;
}
IOReturn IOHIDDeviceGetValue(void *dev, void *elem, void **pValue) {
    if (!pValue) return kSuccess;
    *pValue = (__bridge void *)LOCKED(CurrentValue(OBJ(SHElement, elem))); return kSuccess;
}
IOReturn IOHIDDeviceGetValueWithOptions(void *dev, void *elem, void **pValue, uint32_t options) { return IOHIDDeviceGetValue(dev, elem, pValue); }
IOReturn IOHIDDeviceSetValue(void *dev, void *elem, void *value) { return kSuccess; }   // no output elements
IOReturn IOHIDDeviceGetReport(void *dev, uint32_t type, CFIndex reportID, uint8_t *report, CFIndex *len) {
    static _Atomic int asked; if (asked++ < 3) TRACE("GetReport type %u id %ld", type, (long)reportID);
    if (type != 0 || !report || !len) return kUnsupported;   // input reports only
    CFIndex n = MIN(*len, REPORT_LEN); [gLock lock]; memcpy(report, OBJ(SHDevice, dev)->report, n); [gLock unlock]; *len = n; return kSuccess;
}
// Output (rumble, LEDs) is accepted and dropped. ponytail: route report 3 (Xbox rumble) to GCController haptics when a
// game's feel depends on it.
IOReturn IOHIDDeviceSetReport(void *dev, uint32_t type, CFIndex reportID, const uint8_t *report, CFIndex len) { return kSuccess; }
IOReturn IOHIDDeviceSetReportWithCallback(void *dev, uint32_t type, CFIndex reportID, const uint8_t *report, CFIndex len, CFTimeInterval timeout,
                                          void (*cb)(void *, IOReturn, void *, uint32_t, uint32_t, uint8_t *, CFIndex), void *ctx) {
    if (cb) {
        SHDevice *d = OBJ(SHDevice, dev); CFRunLoopRef rl; CFStringRef mode; int k = CALLER; [gLock lock]; DeviceLoop(d, k, &rl, &mode); [gLock unlock];
        Post(rl, mode, ^{ cb(ctx, kSuccess, dev, type, (uint32_t)reportID, (uint8_t *)report, len); });
    }
    return kSuccess;
}
void IOHIDDeviceRegisterInputReportCallback(void *dev, uint8_t *buf, CFIndex len, ReportCB cb, void *ctx) {
    SHDevice *d = OBJ(SHDevice, dev); int k = CALLER; SHClient *c = &d->c[k]; TRACE("RegisterInputReportCallback %p len %ld, client %d", d, (long)len, k);
    [gLock lock]; c->reportGen++; c->reportBuf = cb ? buf : NULL; c->reportLen = len; c->reportCB = cb; c->reportTimeCB = NULL; c->reportCtx = ctx;
    ResendReport(d, k); [gLock unlock];
}
void IOHIDDeviceRegisterInputReportWithTimeStampCallback(void *dev, uint8_t *buf, CFIndex len, ReportTimeCB cb, void *ctx) {
    SHDevice *d = OBJ(SHDevice, dev); int k = CALLER; SHClient *c = &d->c[k];
    [gLock lock]; c->reportGen++; c->reportBuf = cb ? buf : NULL; c->reportLen = len; c->reportTimeCB = cb; c->reportCB = NULL; c->reportCtx = ctx;
    ResendReport(d, k); [gLock unlock];
}
void IOHIDDeviceRegisterInputValueCallback(void *dev, ValueCB cb, void *ctx) { SHClient *c = &OBJ(SHDevice, dev)->c[CALLER]; [gLock lock]; c->valueCB = cb; c->valueCtx = ctx; [gLock unlock]; }
void IOHIDDeviceRegisterRemovalCallback(void *dev, CallbackCB cb, void *ctx) { SHClient *c = &OBJ(SHDevice, dev)->c[CALLER]; [gLock lock]; c->removalCB = cb; c->removalCtx = ctx; [gLock unlock]; }
void IOHIDDeviceSetInputValueMatching(void *dev, CFDictionaryRef d) {}
void IOHIDDeviceSetInputValueMatchingMultiple(void *dev, CFArrayRef a) {}
void IOHIDDeviceScheduleWithRunLoop(void *dev, CFRunLoopRef rl, CFStringRef mode) { SHClient *c = &OBJ(SHDevice, dev)->c[CALLER]; TRACE("DeviceScheduleWithRunLoop %s %s", LoopName(rl), Str(mode)); [gLock lock]; SetLoop(&c->rl, &c->mode, rl, mode); [gLock unlock]; }
void IOHIDDeviceUnscheduleFromRunLoop(void *dev, CFRunLoopRef rl, CFStringRef mode) { SHClient *c = &OBJ(SHDevice, dev)->c[CALLER]; [gLock lock]; SetLoop(&c->rl, &c->mode, NULL, NULL); [gLock unlock]; }



// ---- IOHIDElement ------------------------------------------------------------------------------------------------
#define E(x) OBJ(SHElement, x)
CFTypeID IOHIDElementGetTypeID(void) { return RealTypeID("IOHIDElementGetTypeID"); }
uint32_t IOHIDElementGetCookie(void *e) { return E(e)->cookie; }
uint32_t IOHIDElementGetType(void *e) { return E(e)->type; }
uint32_t IOHIDElementGetCollectionType(void *e) { return E(e)->type == kTypeCollection ? 1 /* application */ : 0; }
uint32_t IOHIDElementGetUsagePage(void *e) { return E(e)->spec ? E(e)->spec->page : 1; }
uint32_t IOHIDElementGetUsage(void *e) { return E(e)->spec ? E(e)->spec->usage : 5; }
Boolean IOHIDElementIsVirtual(void *e) { return false; }
Boolean IOHIDElementIsRelative(void *e) { return false; }
Boolean IOHIDElementIsWrapping(void *e) { return false; }
Boolean IOHIDElementIsArray(void *e) { return false; }
Boolean IOHIDElementIsNonLinear(void *e) { return false; }
Boolean IOHIDElementHasPreferredState(void *e) { return true; }
Boolean IOHIDElementHasNullState(void *e) { return E(e)->spec && E(e)->spec->usage == 0x39 && E(e)->spec->page == 1; }
CFStringRef IOHIDElementGetName(void *e) { return NULL; }
uint32_t IOHIDElementGetReportID(void *e) { return 1; }
uint32_t IOHIDElementGetReportSize(void *e) { return E(e)->spec ? E(e)->spec->bits : 0; }
uint32_t IOHIDElementGetReportCount(void *e) { return E(e)->spec ? 1 : 0; }
uint32_t IOHIDElementGetUnit(void *e) { return IOHIDElementHasNullState(e) ? 0x14 : 0; }   // hat: degrees
uint32_t IOHIDElementGetUnitExponent(void *e) { return 0; }
CFIndex IOHIDElementGetLogicalMin(void *e) { return E(e)->spec ? E(e)->spec->min : 0; }
CFIndex IOHIDElementGetLogicalMax(void *e) { return E(e)->spec ? E(e)->spec->max : 0; }
CFIndex IOHIDElementGetPhysicalMin(void *e) { return E(e)->spec ? E(e)->spec->pmin : 0; }
CFIndex IOHIDElementGetPhysicalMax(void *e) { return E(e)->spec ? E(e)->spec->pmax : 0; }
void *IOHIDElementGetDevice(void *e) { return (__bridge void *)E(e)->device; }
void *IOHIDElementGetParent(void *e) { return (__bridge void *)E(e)->parent; }
CFArrayRef IOHIDElementGetChildren(void *e) { return (__bridge CFArrayRef)(E(e)->children ?: @[]); }
CFTypeRef IOHIDElementGetProperty(void *e, CFStringRef key) { return NULL; }
Boolean IOHIDElementSetProperty(void *e, CFStringRef key, CFTypeRef v) { return true; }

// ---- IOHIDValue --------------------------------------------------------------------------------------------------

#define V(x) OBJ(SHValue, x)
CFTypeID IOHIDValueGetTypeID(void) { return RealTypeID("IOHIDValueGetTypeID"); }
void *IOHIDValueCreateWithIntegerValue(CFAllocatorRef a, void *elem, uint64_t t, CFIndex v) { return (void *)CFBridgingRetain(NewValue(E(elem), v, t)); }
void *IOHIDValueGetElement(void *v) { return (__bridge void *)V(v)->element; }
uint64_t IOHIDValueGetTimeStamp(void *v) { return V(v)->time; }
CFIndex IOHIDValueGetLength(void *v) { const Spec *s = V(v)->element->spec; return s ? (s->bits + 7) / 8 : 0; }
const uint8_t *IOHIDValueGetBytePtr(void *v) { return (const uint8_t *)&V(v)->integer; }   // little-endian, so the low bytes come first
CFIndex IOHIDValueGetIntegerValue(void *v) { return V(v)->integer; }
// type 0 = calibrated (-1..1 for axes, 0..1 for one-sided ranges), 1 = physical, 2 = exponent.
double IOHIDValueGetScaledValue(void *v, uint32_t type) {
    const Spec *s = V(v)->element->spec; if (!s || s->max == s->min) return V(v)->integer;
    double t = (double)(V(v)->integer - s->min) / (s->max - s->min);
    if (type == 1) return s->pmin + t * (s->pmax - s->pmin);
    return (s->min == 0 && s->max <= 1023) ? t : t * 2 - 1;
}

// ---- IOHIDQueue --------------------------------------------------------------------------------------------------
#define Q(x) OBJ(SHQueue, x)
CFTypeID IOHIDQueueGetTypeID(void) { return RealTypeID("IOHIDQueueGetTypeID"); }
void *IOHIDQueueCreate(CFAllocatorRef a, void *dev, CFIndex depth, uint32_t options) {
    Start(); TRACE("QueueCreate for %p depth %ld", dev, (long)depth);
    SHQueue *q = [SHQueue new]; q->device = OBJ(SHDevice, dev); q->depth = MAX(depth, 1); q->client = CALLER;
    q->elements = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]; q->pending = [NSMutableArray array];
    [gLock lock]; [gQueues addObject:q]; [gLock unlock];
    return (void *)CFBridgingRetain(q);
}
void *IOHIDQueueGetDevice(void *q) { return (__bridge void *)Q(q)->device; }
CFIndex IOHIDQueueGetDepth(void *q) { return Q(q)->depth; }
void IOHIDQueueSetDepth(void *q, CFIndex depth) { Q(q)->depth = MAX(depth, 1); }
void IOHIDQueueAddElement(void *q, void *e) { [gLock lock]; [Q(q)->elements addObject:E(e)]; [gLock unlock]; }
void IOHIDQueueRemoveElement(void *q, void *e) { [gLock lock]; [Q(q)->elements removeObject:E(e)]; [gLock unlock]; }
Boolean IOHIDQueueContainsElement(void *q, void *e) { return LOCKED([Q(q)->elements containsObject:E(e)]); }
// A real pad's sticks jitter, so a consumer learns every element's value within milliseconds of starting. Unity's
// legacy joystick path starts from 0 per element (full deflection on 0..65535 axes: the menu scrolled on its own), so a
// starting queue gets the current value of each queued element once.
void IOHIDQueueStart(void *q) {
    SHQueue *x = Q(q); [gLock lock];
    if (!x->started) for (SHElement *e in x->device->elements) if (e->spec && [x->elements containsObject:e]) [x->pending addObject:CurrentValue(e)];
    x->started = YES; [gLock unlock];
}
void IOHIDQueueStop(void *q) { [gLock lock]; Q(q)->started = NO; [gLock unlock]; }
// ponytail: never blocks for `timeout`; every caller seen polls once per frame.
void *IOHIDQueueCopyNextValueWithTimeout(void *q, CFTimeInterval timeout) {
   
    SHQueue *x = Q(q); SHValue *v = nil;
    [gLock lock]; if (x->pending.count) { v = x->pending[0]; [x->pending removeObjectAtIndex:0]; } [gLock unlock];
    return v ? (void *)CFBridgingRetain(v) : NULL;
}
void *IOHIDQueueCopyNextValue(void *q) { return IOHIDQueueCopyNextValueWithTimeout(q, 0); }
void IOHIDQueueRegisterValueAvailableCallback(void *q, CallbackCB cb, void *ctx) { [gLock lock]; Q(q)->availCB = cb; Q(q)->availCtx = ctx; [gLock unlock]; }
void IOHIDQueueScheduleWithRunLoop(void *q, CFRunLoopRef rl, CFStringRef mode) { TRACE("QueueScheduleWithRunLoop %s %s", LoopName(rl), Str(mode)); [gLock lock]; SetLoop(&Q(q)->rl, &Q(q)->mode, rl, mode); [gLock unlock]; }
void IOHIDQueueUnscheduleFromRunLoop(void *q, CFRunLoopRef rl, CFStringRef mode) { [gLock lock]; SetLoop(&Q(q)->rl, &Q(q)->mode, NULL, NULL); [gLock unlock]; }

// A second guest (a game the Steam client started) ended: its managers, queues, watchers and pad callbacks are dropped,
// as a Mac process's are when it exits. Its code stays loaded, and a callback into it after its teardown crashed
// (the on-screen controller announced to Tunic's HID manager after Tunic quit, 2026-10-04).
void ShackHIDForgetSecondGuest(void) {
    if (!gLock) return;
    [gLock lock];
    for (SHManager *m in gManagers.allObjects) if (m->client == 1) {
        m->open = NO; m->matchCB = m->removeCB = NULL; m->valueCB = NULL; m->reportCB = NULL; [m->announced removeAllObjects];
        [gManagers removeObject:m];
    }
    for (SHQueue *q in gQueues.allObjects) if (q->client == 1) { q->started = NO; q->availCB = NULL; [gQueues removeObject:q]; }
    for (SHDevice *d in gDevices) { SetLoop(&d->c[1].rl, &d->c[1].mode, NULL, NULL); NSUInteger gen = d->c[1].reportGen + 1; d->c[1] = (SHClient){ .reportGen = gen }; }
    [gWatchers filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SHWatcher *w, NSDictionary *b) { return w->client != 1; }]];
    [gLock unlock];
    fprintf(stderr, "[ShackHID] the second guest ended: its pad clients are gone\n");
}

// The pad identity for a game that starts after the pads exist (the Steam client's, where SHACK_HID_PAD came too late):
// each pad becomes a new device with it, as if unplugged and plugged in again; the first guest sees that too.
void ShackHIDSetXbox2016(BOOL on) {
    Start();
    if (gPadsOff || on == gXbox2016) return;
    [gLock lock];
    gXbox2016 = on;
    for (SHDevice *d in [gDevices copy]) if (d->gc) { GCController *gc = d->gc; Detach(gc); Attach(gc); }
    [gLock unlock];
}

#ifdef SHACK_HID_TEST
// SHACK_HID_FAKE=1 (Mac repro builds): a pad appears after 15 s and presses A for 0.3 s every 3 s.
__attribute__((constructor)) static void FakePresses(void) {
    if (!getenv("SHACK_HID_FAKE")) return;
    [NSThread detachNewThreadWithBlock:^{
        sleep(15); extern void *ShackHIDTestAddPad(void); extern void ShackHIDTestSet(void *, float, float, float, BOOL, BOOL, uint32_t);
        void *d = ShackHIDTestAddPad(); fprintf(stderr, "[ShackHID] fake pad added\n");
        for (;;) { sleep(3); fprintf(stderr, "[ShackHID] fake A down\n"); ShackHIDTestSet(d, 0, 0, 0, NO, NO, kA); usleep(300000); ShackHIDTestSet(d, 0, 0, 0, NO, NO, 0); }
    }];
}
// The loader calls this on the main thread just before the game starts: pads that are already connected are registered
// now, so the game's first HID scan sees them (a later pad reaches SDL2 only through NotifyWatchers); Attach from Start
// is asynchronous and the main thread is busy loading the game's libraries at that moment.
void ShackHIDPrewarm(void) {
    Start();
    if (gPadsOff || !NSThread.isMainThread) return;
    for (GCController *c in GCController.controllers) Attach(c);
    fprintf(stderr, "[ShackHID] prewarm: %lu pad(s) before the game starts\n", (unsigned long)gDevices.count);
}
// Test hooks (host/probe/test_shack_hid.m): a pad without GameController, and a way to move its sticks and buttons.
void *ShackHIDTestAddPad(void) { Start(); [gLock lock]; SHDevice *d = NewDevice(nil, 99); [gDevices addObject:d]; for (SHManager *m in gManagers) Announce(m); NotifyWatchers(d, NO); PollWhilePads(); [gLock unlock]; return (__bridge void *)d; }
void ShackHIDTestRemovePads(void) { Detach(nil); }   // every test pad (they have no GCController)
void ShackHIDTestSet(void *dev, float lx, float ly, float lt, BOOL up, BOOL right, uint32_t buttons) {
    PadInput in = { lx, ly, 0, 0, lt, 0, up, NO, NO, right, buttons }; uint8_t r[REPORT_LEN]; Encode(&in, r);
    [gLock lock]; Deliver(OBJ(SHDevice, dev), r); [gLock unlock];
}
#endif
