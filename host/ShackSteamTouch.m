#import "ShackSteamTouch.h"
#import <math.h>
#import <stdatomic.h>

// CEF 126's C API (include/capi, branch 6478), only the members used, by position. Steam builds its own CEF, so every
// struct's size (its first field) is checked against these before a member past the base is read; a size that differs
// is logged and the finger stays a mouse.
typedef struct cef_base { size_t size; void (*add_ref)(struct cef_base *); int (*release)(struct cef_base *); void *has_one_ref, *has_at_least_one_ref; } cef_base;
typedef struct cef_browser_host {   // 68 functions
    cef_base base;
    void *get_browser, *close_browser, *try_close_browser, *set_focus;
    void *(*get_window_handle)(struct cef_browser_host *);   // the browser's NSView
    void *other1[7];
    double (*get_zoom_level)(struct cef_browser_host *);
    void *other2[11];
    int (*send_dev_tools_message)(struct cef_browser_host *, const void *message, size_t size);
    void *rest[43];
} cef_browser_host;
typedef struct cef_browser {   // 21 functions
    cef_base base;
    int (*is_valid)(struct cef_browser *);
    cef_browser_host *(*get_host)(struct cef_browser *);
    void *other[8];
    int (*get_identifier)(struct cef_browser *);
    void *rest[10];
} cef_browser;
struct cef_client;
typedef struct cef_life_span_handler {   // 5 functions
    cef_base base;
    int (*on_before_popup)(struct cef_life_span_handler *, cef_browser *, void *frame, const void *url, const void *name, int disposition,
                           int gesture, const void *features, void *window_info, struct cef_client **client, void *settings, void **extra, int *no_js);
    void *on_before_dev_tools_popup;
    void (*on_after_created)(struct cef_life_span_handler *, cef_browser *);
    void *do_close;
    void (*on_before_close)(struct cef_life_span_handler *, cef_browser *);
} cef_life_span_handler;
typedef struct cef_client {   // 19 functions
    cef_base base;
    void *getters[13];   // audio .. keyboard
    cef_life_span_handler *(*get_life_span_handler)(struct cef_client *);
    void *rest[5];
} cef_client;
typedef int (*create_browser_fn)(const void *window_info, cef_client *client, const void *url, const void *settings, void *extra, void *context);

static BOOL sized(const void *s, size_t want, const char *what) {
    size_t have = s ? *(const size_t *)s : 0;
    if (have >= want) return YES;   // ponytail: Valve may append members (its CefTouchHandler); a member moved inside is not caught
    static _Atomic int told;
    if (atomic_fetch_add(&told, 1) < 8) NSLog(@"[MacShack] Steam touch: %s is %zu bytes, CEF 126's is %zu; fingers stay a mouse", what, have, want);
    return NO;
}

// Steam's browsers, add_ref'd from created to closing. CEF hands out a new struct for the same browser on each call:
// one is matched by its identifier. ponytail: a fixed table; Big Picture has five or so.
static cef_browser *gBrowsers[32];
static cef_browser *gActive;   // the browser that took the current finger
static create_browser_fn origCreate;

static void remember(cef_browser *b) {
    cef_browser_host *host = sized(b, sizeof *b, "cef_browser_t") ? b->get_host(b) : NULL;   // a reference of ours
    if (host && sized(host, sizeof *host, "cef_browser_host_t")) {
        for (int i = 0; i < 32; i++) if (!gBrowsers[i]) { b->base.add_ref(&b->base); gBrowsers[i] = b; break; }
        static _Atomic int told;
        if (atomic_fetch_add(&told, 1) < 16) NSLog(@"[MacShack] Steam touch: browser %d, view %p", b->get_identifier(b), host->get_window_handle(host));
    }
    if (host) host->base.release(&host->base);
}
static void forget(cef_browser *b) {
    int closing = b->get_identifier(b);
    for (int i = 0; i < 32; i++) {
        cef_browser *mine = gBrowsers[i];
        if (!mine || mine->get_identifier(mine) != closing) continue;
        gBrowsers[i] = NULL;
        if (gActive == mine) gActive = NULL;
        mine->base.release(&mine->base);
    }
}

// Steam's clients and life span handlers are C++ classes behind CEF's C wrapper: each class's functions are the same for
// all its structs, and the wrapper makes a new handler struct on every get_life_span_handler call. Each class found gets
// its own set of wrappers and originals. Big Picture's windows are popups of its SharedJSContext, each with a client
// Steam hands over in on_before_popup. ponytail: four classes; another is logged and left alone.
#define CLASSES 4
static cef_life_span_handler *(*origGetHandler[CLASSES])(cef_client *);
static void (*origAfter[CLASSES])(cef_life_span_handler *, cef_browser *), (*origClose[CLASSES])(cef_life_span_handler *, cef_browser *);
static int (*origPopup[CLASSES])(cef_life_span_handler *, cef_browser *, void *, const void *, const void *, int, int, const void *, void *, cef_client **, void *, void **, int *);
static void patchClient(cef_client *c);
static cef_life_span_handler *patchHandler(cef_life_span_handler *h);
#define CLASS(n) \
    static cef_life_span_handler *getHandler##n(cef_client *c) { return patchHandler(origGetHandler[n](c)); } \
    static void after##n(cef_life_span_handler *h, cef_browser *b) { remember(b); origAfter[n](h, b); } \
    static void close##n(cef_life_span_handler *h, cef_browser *b) { forget(b); origClose[n](h, b); } \
    static int popup##n(cef_life_span_handler *h, cef_browser *b, void *frame, const void *url, const void *name, int disposition, int gesture, \
                        const void *features, void *window_info, cef_client **client, void *settings, void **extra, int *no_js) { \
        int cancel = origPopup[n](h, b, frame, url, name, disposition, gesture, features, window_info, client, settings, extra, no_js); \
        if (client && *client) patchClient(*client); \
        return cancel; \
    }
CLASS(0) CLASS(1) CLASS(2) CLASS(3)
static cef_life_span_handler *(*const getHandlers[CLASSES])(cef_client *) = {getHandler0, getHandler1, getHandler2, getHandler3};
static void (*const afters[CLASSES])(cef_life_span_handler *, cef_browser *) = {after0, after1, after2, after3};
static void (*const closes[CLASSES])(cef_life_span_handler *, cef_browser *) = {close0, close1, close2, close3};
static int (*const popups[CLASSES])(cef_life_span_handler *, cef_browser *, void *, const void *, const void *, int, int, const void *, void *, cef_client **, void *, void **, int *) = {popup0, popup1, popup2, popup3};

// The class's slot in table (its original there, or the first free one), or -1: already ours, or no room.
static int classSlot(void **table, void *const *ours, void *fn, const char *what) {
    for (int i = 0; i < CLASSES; i++) if (fn == ours[i]) return -1;
    for (int i = 0; i < CLASSES; i++) if (table[i] == fn || !table[i]) { table[i] = fn; return i; }
    static _Atomic int told;
    if (atomic_fetch_add(&told, 1) < 4) NSLog(@"[MacShack] Steam touch: a fifth %s class, left alone", what);
    return -1;
}
static void patchClient(cef_client *c) {
    if (!sized(c, sizeof *c, "cef_client_t")) return;
    int i = classSlot((void **)origGetHandler, (void *const *)getHandlers, (void *)c->get_life_span_handler, "client");
    if (i >= 0) c->get_life_span_handler = getHandlers[i];
}
static cef_life_span_handler *patchHandler(cef_life_span_handler *h) {
    if (!h || !sized(h, sizeof *h, "cef_life_span_handler_t")) return h;
    int i = classSlot((void **)origAfter, (void *const *)afters, (void *)h->on_after_created, "life span handler");
    if (i < 0) return h;
    origClose[i] = h->on_before_close; origPopup[i] = h->on_before_popup;   // ponytail: one class, one set of functions
    h->on_after_created = afters[i]; h->on_before_close = closes[i]; h->on_before_popup = popups[i];
    return h;
}
static int createBrowser(const void *window_info, cef_client *client, const void *url, const void *settings, void *extra, void *context) {
    if (client) patchClient(client);
    return origCreate(window_info, client, url, settings, extra, context);
}

void ShackAppKitSetDirectTouch(BOOL (*fn)(id, int, CGPoint));   // libShackAppKit (ShackHostView.m)
void ShackAppKitSetDirectScroll(BOOL (*fn)(id, CGPoint, CGPoint));
void *ShackSteamTouchCreateBrowser(void *real) {
    if (!real) return real;
    origCreate = real;
    ShackAppKitSetDirectTouch(ShackSteamTouch);
    ShackAppKitSetDirectScroll(ShackSteamScroll);
    return (void *)createBrowser;
}

@interface NSObject (ShackSteamTouchView)
- (id)superview; - (CGRect)frame;   // libShackAppKit's NSView
@end
static CGRect frameOf(id v) { return [v respondsToSelector:@selector(frame)] ? [v frame] : (CGRect){{0, 0}, {0, 0}}; }
static id gActiveView;   // the Steam browser view under the current finger
// The browser whose view is view or holds it (CEF lays views of its own over parts of a page: CefNonDraggableView).
static cef_browser *browserForView(id view, id *found) {
    for (id v = view; v; v = [v superview])
        for (int i = 0; i < 32; i++) {
            cef_browser *b = gBrowsers[i];
            if (!b) continue;
            cef_browser_host *host = b->get_host(b);
            BOOL match = host->get_window_handle(host) == (__bridge void *)v;
            host->base.release(&host->base);
            if (match) { *found = v; return b; }
        }
    return nil;
}
// A window point (AppKit: origin bottom-left) in a view's points, top-left origin. Frames are in the superview's
// coordinates, bottom-left, as the shim lays them out.
static CGPoint pointInView(CGPoint w, id view) {
    CGPoint origin = {0, 0};
    for (id v = view; v; v = [v superview]) { origin.x += frameOf(v).origin.x; origin.y += frameOf(v).origin.y; }
    return CGPointMake(w.x - origin.x, frameOf(view).size.height - (w.y - origin.y));
}

BOOL ShackSteamTouch(id view, int phase, CGPoint w) {
    if (phase == 0) { id found = nil; gActive = browserForView(view, &found); gActiveView = found; }
    cef_browser *b = gActive;
    if (!b) return NO;
    CGPoint p = pointInView(w, gActiveView);
    if (phase >= 2) { gActive = NULL; gActiveView = nil; }
    cef_browser_host *host = b->get_host(b);
    double zoom = pow(1.2, host->get_zoom_level(host));   // CSS pixels; Chromium's zoom levels are powers of 1.2
    static const char *types[] = {"touchStart", "touchMove", "touchEnd", "touchCancel"};
    static int ids = 1000000;   // ponytail: replies are dropped (no observer); ids only need to be unique
    char json[256];
    int n = phase >= 2
        ? snprintf(json, sizeof json, "{\"id\":%d,\"method\":\"Input.dispatchTouchEvent\",\"params\":{\"type\":\"%s\",\"touchPoints\":[]}}", ids++, types[phase])
        : snprintf(json, sizeof json, "{\"id\":%d,\"method\":\"Input.dispatchTouchEvent\",\"params\":{\"type\":\"%s\",\"touchPoints\":[{\"x\":%.2f,\"y\":%.2f}]}}",
                   ids++, types[phase], p.x / zoom, p.y / zoom);
    int sent = host->send_dev_tools_message(host, json, (size_t)n);
    host->base.release(&host->base);
    static _Atomic int told;
    if (!sent && atomic_fetch_add(&told, 1) < 8) NSLog(@"[MacShack] Steam touch: send_dev_tools_message refused %s (not the UI thread?)", json);
    return YES;
}

// A pointer's scroll over a Steam browser: its own wheel event (Mac Chromium leaves a shim's scroll wheel event alone).
BOOL ShackSteamScroll(id view, CGPoint w, CGPoint d) {
    id found = nil;
    cef_browser *b = browserForView(view, &found);
    if (!b) return NO;
    CGPoint p = pointInView(w, found);
    cef_browser_host *host = b->get_host(b);
    double zoom = pow(1.2, host->get_zoom_level(host));
    static int ids = 2000000;
    char json[256];   // deltaY > 0 scrolls down: the content moves up, against the fingers' d
    int n = snprintf(json, sizeof json, "{\"id\":%d,\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseWheel\",\"x\":%.2f,\"y\":%.2f,\"deltaX\":%.2f,\"deltaY\":%.2f}}",
                     ids++, p.x / zoom, p.y / zoom, 0.0 - d.x / zoom, 0.0 - d.y / zoom);
    host->send_dev_tools_message(host, json, (size_t)n);
    host->base.release(&host->base);
    return YES;
}
