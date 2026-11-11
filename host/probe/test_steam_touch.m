// Mac check: clang -fobjc-arc host/ShackSteamTouch.m host/probe/test_steam_touch.m -framework Foundation -o /tmp/t && /tmp/t
// Fake CEF 126 structs, built from the header's member positions (not ShackSteamTouch.m's types): a browser created
// through the wrapped cef_browser_host_create_browser gets fingers as DevTools touch events, and loses them on close.
#import <Foundation/Foundation.h>
#import "../ShackSteamTouch.h"

static void Check(BOOL ok, const char *what) { if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); } }
#define SLOT(s, i) (((void **)(s))[5 + (i)])   // after cef_base_ref_counted_t: size + 4 functions

static BOOL (*gTaker)(id, int, CGPoint);
void ShackAppKitSetDirectTouch(BOOL (*fn)(id, int, CGPoint)) { gTaker = fn; }
static BOOL (*gScroller)(id, CGPoint, CGPoint);
void ShackAppKitSetDirectScroll(BOOL (*fn)(id, CGPoint, CGPoint)) { gScroller = fn; }

@interface FakeView : NSObject
@property (nonatomic, strong) FakeView *superview;
@property (nonatomic) CGRect frame;   // in the superview, bottom-left origin, as the shim's NSView
@end
@implementation FakeView @end

static int refs;   // add_ref minus release over every fake
static void addRef(void *s) { refs++; }
static int releaseRef(void *s) { refs--; return 1; }
static void *make(size_t size) {
    void **s = calloc(1, size);
    *(size_t *)s = size; s[1] = addRef; s[2] = releaseRef;
    return s;
}

static FakeView *gBrowserView;
static double gZoom;
static NSMutableArray<NSString *> *gSent;
static void *windowHandle(void *host) { return (__bridge void *)gBrowserView; }
static double zoomLevel(void *host) { return gZoom; }
static int sendDevTools(void *host, const void *msg, size_t n) { [gSent addObject:[[NSString alloc] initWithBytes:msg length:n encoding:NSUTF8StringEncoding]]; return 1; }
static void *gHost;
static void *getHost(void *browser) { refs++; return gHost; }   // returns a reference, as CEF does
static int identifier(void *browser) { return 7; }
static void *newBrowser(void) {   // CEF wraps the same browser in a new struct on each call
    void *b = make(40 + 21 * 8);
    SLOT(b, 1) = getHost; SLOT(b, 10) = identifier;
    return b;
}

// SharedJSContext: a browser of the first client class, with no view.
static void *gHiddenHost;
static void *noWindow(void *host) { return NULL; }
static void *getHiddenHost(void *browser) { refs++; return gHiddenHost; }
static int hiddenIdentifier(void *browser) { return 1; }
static void *newHiddenBrowser(void) {
    void *b = make(40 + 21 * 8);
    SLOT(b, 1) = getHiddenHost; SLOT(b, 10) = hiddenIdentifier;
    return b;
}

static int afterCalls, closeCalls, popupCalls;
static void origAfter(void *h, void *b) { afterCalls++; }
static void origClose(void *h, void *b) { closeCalls++; }
static void *origGetLifeSpan2(void *client);
static void *gPopupClient;   // Big Picture's window: a popup with a client of another class
static int origPopup(void *h, void *b, void *f, const void *u, const void *n, int d, int g, const void *pf, void *wi, void **client, void *s, void **e, int *nj) {
    popupCalls++;
    *client = gPopupClient;
    return 0;
}
static void *origGetLifeSpan(void *client) {   // a new handler struct each time, as CEF's C++ wrapper does
    void *h = make(40 + 5 * 8);
    SLOT(h, 0) = origPopup; SLOT(h, 2) = origAfter; SLOT(h, 4) = origClose;
    return h;
}
static void origAfter2(void *h, void *b) { afterCalls++; }
static void origClose2(void *h, void *b) { closeCalls++; }
static void *origGetLifeSpan2(void *client) {
    void *h = make(40 + 5 * 8);
    SLOT(h, 0) = origPopup; SLOT(h, 2) = origAfter2; SLOT(h, 4) = origClose2;
    return h;
}
static int createCalls;
static int realCreate(const void *wi, void *client, const void *url, const void *settings, void *extra, void *ctx) { createCalls++; return 1; }

int main(void) {
    @autoreleasepool {
        gSent = [NSMutableArray array];
        gHost = make(40 + 68 * 8);
        SLOT(gHost, 4) = windowHandle; SLOT(gHost, 12) = zoomLevel; SLOT(gHost, 24) = sendDevTools;
        gHiddenHost = make(40 + 68 * 8);
        SLOT(gHiddenHost, 4) = noWindow; SLOT(gHiddenHost, 12) = zoomLevel; SLOT(gHiddenHost, 24) = sendDevTools;
        gBrowserView = [FakeView new]; gBrowserView.frame = CGRectMake(0, 0, 1600, 1200);   // Big Picture's, as on the iPad
        FakeView *render = [FakeView new]; render.superview = gBrowserView; render.frame = gBrowserView.frame;   // the view under the finger
        FakeView *other = [FakeView new];

        int (*create)(const void *, void *, const void *, const void *, void *, void *) = ShackSteamTouchCreateBrowser(realCreate);
        Check(create && create != realCreate && gTaker, "create_browser wrapped and the taker installed");
        void *client = make(40 + 19 * 8);
        SLOT(client, 13) = origGetLifeSpan;
        Check(create(NULL, client, NULL, NULL, NULL, NULL) == 1 && createCalls == 1, "real create_browser called");
        Check(SLOT(client, 13) != origGetLifeSpan, "client's get_life_span_handler wrapped");

        Check(!gTaker(render, 0, CGPointMake(1, 1)), "no browser yet: the finger stays a mouse");
        void *(*getLifeSpan)(void *) = SLOT(client, 13);
        void *h = getLifeSpan(client);
        Check(SLOT(h, 0) != origPopup && SLOT(h, 2) != origAfter && SLOT(h, 4) != origClose, "handler's popup, created and close wrapped");
        ((void (*)(void *, void *))SLOT(h, 2))(h, newHiddenBrowser());
        Check(afterCalls == 1 && refs == 1, "Steam's on_after_created called; SharedJSContext kept (one reference)");
        Check(!gTaker(render, 0, CGPointMake(1, 1)), "a browser with no view takes no finger");

        gPopupClient = make(40 + 19 * 8);
        SLOT(gPopupClient, 13) = origGetLifeSpan2;
        void *popupClient = NULL;
        ((int (*)(void *, void *, void *, const void *, const void *, int, int, const void *, void *, void **, void *, void **, int *))SLOT(h, 0))(
            h, NULL, NULL, NULL, NULL, 0, 1, NULL, NULL, &popupClient, NULL, NULL, NULL);
        Check(popupCalls == 1 && popupClient == gPopupClient && SLOT(gPopupClient, 13) != origGetLifeSpan2, "the popup's client, of another class, wrapped");
        void *(*getLifeSpan2)(void *) = SLOT(gPopupClient, 13);
        void *hp = getLifeSpan2(gPopupClient);
        Check(SLOT(hp, 2) != origAfter2 && SLOT(hp, 2) != SLOT(h, 2), "the popup's handler wrapped by its own class's wrapper");
        ((void (*)(void *, void *))SLOT(hp, 2))(hp, newBrowser());
        Check(afterCalls == 2 && refs == 2, "Big Picture's browser kept");
        Check(SLOT(getLifeSpan(client), 2) == SLOT(h, 2), "the first class keeps its wrapper");

        Check(gTaker(render, 0, CGPointMake(100, 1000)), "a finger on the browser's view taken");
        Check([gSent.lastObject containsString:@"\"method\":\"Input.dispatchTouchEvent\""] &&
              [gSent.lastObject containsString:@"\"type\":\"touchStart\",\"touchPoints\":[{\"x\":100.00,\"y\":200.00}]"], "touchStart at the finger");
        gZoom = 1;
        Check(gTaker(other, 1, CGPointMake(120, 960)), "a move goes to the browser that took the finger");
        Check([gSent.lastObject containsString:@"\"type\":\"touchMove\",\"touchPoints\":[{\"x\":100.00,\"y\":200.00}]"], "touchMove in CSS pixels (zoom level 1 = 1.2x)");
        Check(gTaker(render, 2, CGPointMake(0, 0)) && [gSent.lastObject containsString:@"\"type\":\"touchEnd\",\"touchPoints\":[]"], "touchEnd");
        gZoom = 0;
        // The install dialog: CEF's CefNonDraggableView over part of the page, the view under the finger. The point is
        // the browser view's, not the overlay's (it came out above the page: y -305).
        FakeView *overlay = [FakeView new]; overlay.superview = gBrowserView; overlay.frame = CGRectMake(517, 442, 566, 280);
        Check(gTaker(overlay, 0, CGPointMake(751, 600)) && [gSent.lastObject containsString:@"[{\"x\":751.00,\"y\":600.00}]"], "a finger on CEF's overlay view, in the browser view's points");
        gTaker(overlay, 2, CGPointMake(751, 600));
        // A browser view away from the window's corner: its frame, and its ancestors', are taken off.
        FakeView *holder = [FakeView new]; holder.frame = CGRectMake(40, 30, 1000, 800);
        gBrowserView.superview = holder; gBrowserView.frame = CGRectMake(60, 20, 600, 400);
        Check(gTaker(render, 0, CGPointMake(150, 350)) && [gSent.lastObject containsString:@"[{\"x\":50.00,\"y\":100.00}]"], "a browser view's own origin");
        gTaker(render, 2, CGPointMake(0, 0));
        gBrowserView.superview = nil; gBrowserView.frame = CGRectMake(0, 0, 1600, 1200);
        Check(!gTaker(other, 1, CGPointMake(0, 0)), "after the end, nothing is taken");
        Check(!gTaker(other, 0, CGPointMake(0, 0)), "a finger elsewhere stays a mouse");
        Check(gTaker(render, 0, CGPointMake(0, 0)) && gTaker(render, 3, CGPointMake(0, 0)) && [gSent.lastObject containsString:@"\"type\":\"touchCancel\""], "touchCancel");
        // A trackpad's two fingers moving up 30 points over the page: the wheel scrolls down 30 CSS pixels, at the pointer.
        Check(gScroller && gScroller(render, CGPointMake(100, 1000), CGPointMake(0, -30)), "a scroll over the browser taken");
        Check([gSent.lastObject containsString:@"\"type\":\"mouseWheel\",\"x\":100.00,\"y\":200.00,\"deltaX\":0.00,\"deltaY\":30.00"], "mouseWheel down, at the pointer");
        gZoom = 1;
        gScroller(render, CGPointMake(0, 1200), CGPointMake(12, 0));
        Check([gSent.lastObject containsString:@"\"deltaX\":-10.00"], "sideways, in CSS pixels at zoom level 1");
        gZoom = 0;
        Check(!gScroller(other, CGPointMake(0, 0), CGPointMake(0, 5)), "a scroll elsewhere stays a scroll wheel event");
        Check(refs == 2, "host references balanced");

        void *h2 = getLifeSpan(client);
        ((void (*)(void *, void *))SLOT(h2, 4))(h2, newBrowser());   // the same browser, another struct
        Check(closeCalls == 1 && refs == 1, "on close Big Picture's browser is let go (closed through the first class: matched by identifier)");
        Check(!gTaker(render, 0, CGPointMake(0, 0)), "a closed browser takes no finger");

        void *small = make(40 + 2 * 8);   // a client struct of another CEF: left alone
        void *before = SLOT(small, 1);
        create(NULL, small, NULL, NULL, NULL, NULL);
        Check(SLOT(small, 1) == before, "an undersized client is not touched");
    }
    puts("steam touch ok");
    return 0;
}
