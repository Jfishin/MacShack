// metalgldrv (github.com/bomberfish/metalgldrv, MIT): desktop OpenGL 4.6 on Metal 4 in place of the ES 3 layer, for a game
// whose .args has --shack-env=SHACK_GL=metalgldrv (beside SHACK_OPENGL=1). The driver's iOS build speaks EGL only, so the
// CGL and NSOpenGLContext a Mac game uses run here on EGL: a CGL context is an EGL context and, once a view is attached, a
// window surface on a CAMetalLayer inside the view's layer. The game's gl* lookups go to the driver and its CGL context
// calls to the functions below (ShackGLGetProcAddress, ShackHooks); renderer queries and CGLLockContext stay
// libShackOpenGL's. libmetalgldrv.dylib (the driver's cmake/ios.cmake build) goes in the app's Frameworks.
// host/probe/test_gldrv.m checks the CGL part on the Mac (SHACK_GLDRV_TEST: no AppKit shim there).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#ifndef SHACK_GLDRV_TEST
#import "ShackAppKit.h"
#else
static inline void ShackMainSync(dispatch_block_t b) { if (NSThread.isMainThread) b(); else dispatch_sync(dispatch_get_main_queue(), b); }
#endif

typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef int32_t EGLint;
typedef unsigned EGLBoolean, EGLenum;
enum {
    EGL_ALPHA_SIZE = 0x3021, EGL_BLUE_SIZE = 0x3022, EGL_GREEN_SIZE = 0x3023, EGL_RED_SIZE = 0x3024, EGL_DEPTH_SIZE = 0x3025,
    EGL_STENCIL_SIZE = 0x3026, EGL_SAMPLES = 0x3031, EGL_SURFACE_TYPE = 0x3033, EGL_NONE = 0x3038, EGL_RENDERABLE_TYPE = 0x3040,
    EGL_WINDOW_BIT = 0x0004, EGL_OPENGL_BIT = 0x0008, EGL_OPENGL_API = 0x30A2, EGL_CONTEXT_MAJOR_VERSION = 0x3098,
    EGL_CONTEXT_MINOR_VERSION = 0x30FB, EGL_CONTEXT_OPENGL_PROFILE_MASK = 0x30FD,
    EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT = 1, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT = 2,
};
typedef int DrvError, GLint;
enum { kDrvOK = 0, kDrvBadAttribute = 10000, kDrvBadPixelFormat = 10002, kDrvBadContext = 10004, kDrvBadDrawable = 10006 };
enum { kSwapInterval = 222, kSurfaceBackingSize = 304, kEnableSurfaceBackingSize = 305 };

static struct {
    EGLDisplay (*GetDisplay)(void *);
    EGLBoolean (*Initialize)(EGLDisplay, EGLint *, EGLint *);
    EGLBoolean (*BindAPI)(EGLenum);
    EGLBoolean (*ChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    EGLBoolean (*DestroyContext)(EGLDisplay, EGLContext);
    EGLSurface (*CreateWindowSurface)(EGLDisplay, EGLConfig, void *, const EGLint *);
    EGLBoolean (*DestroySurface)(EGLDisplay, EGLSurface);
    EGLBoolean (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    EGLBoolean (*SwapBuffers)(EGLDisplay, EGLSurface);
    EGLBoolean (*SwapInterval)(EGLDisplay, EGLint);
    EGLint (*GetError)(void);
} egl;
static EGLDisplay gDisplay;

static void *driver(void) {   // NULL unless SHACK_GL=metalgldrv and the driver has a Metal 4 GPU
    static void *lib;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("SHACK_GL");
        if (!e || strcmp(e, "metalgldrv")) return;
        void *h = dlopen("@rpath/libmetalgldrv.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!h) { NSLog(@"[ShackGL] metalgldrv: %s", dlerror()); return; }
#define LOAD(f) *(void **)&egl.f = dlsym(h, "egl" #f)
        LOAD(GetDisplay); LOAD(Initialize); LOAD(BindAPI); LOAD(ChooseConfig); LOAD(CreateContext); LOAD(DestroyContext);
        LOAD(CreateWindowSurface); LOAD(DestroySurface); LOAD(MakeCurrent); LOAD(SwapBuffers); LOAD(SwapInterval); LOAD(GetError);
#undef LOAD
        int (*supported)(void) = (int (*)(void))dlsym(h, "metalgldrv_is_supported");
        const char *(*version)(void) = (const char *(*)(void))dlsym(h, "metalgldrv_version");
        EGLint major = 0, minor = 0;
        if (!supported || !supported() || !(gDisplay = egl.GetDisplay(NULL)) || !egl.Initialize(gDisplay, &major, &minor)) {
            NSLog(@"[ShackGL] metalgldrv: no Metal 4 GPU or EGL failed; the ES layer stays");
            return;
        }
        NSLog(@"[ShackGL] metalgldrv %s on, EGL %d.%d", version ? version() : "?", major, minor);
        lib = h;
    });
    return lib;
}
BOOL ShackGLDrvOn(void) { return driver() != NULL; }
#ifdef SHACK_GLDRV_TEST
static int gMakeCurrentCalls;
int ShackGLDrvMakeCurrentCalls(void) { return gMakeCurrentCalls; }
#endif
static EGLBoolean makeCurrent(EGLSurface surface, EGLContext ctx) {
#ifdef SHACK_GLDRV_TEST
    gMakeCurrentCalls++;
#endif
    return egl.MakeCurrent(gDisplay, surface, surface, ctx);
}

@interface ShackDrvFormat : NSObject { @public EGLConfig config; BOOL core; } @end
@implementation ShackDrvFormat @end

// A CGL context. The window surface's CAMetalLayer sits in `box`, the view's layer: the size of the view in points
// (Apple's GL without wantsBestResolutionOpenGLSurface), or the surface backing size stretched over the view.
@interface ShackDrvContext : NSObject {
@public
    EGLContext ctx; EGLSurface surface; ShackDrvFormat *format;
    CALayer *box; CAMetalLayer *layer; BOOL best;
    GLint backing[2]; BOOL backingOn; GLint interval;
    CGSize laidBox, laidSize;   // what the layer was last laid out for
}
@end
@implementation ShackDrvContext
- (void)dealloc {
    if (surface) egl.DestroySurface(gDisplay, surface);
    if (ctx) egl.DestroyContext(gDisplay, ctx);
}
@end

static __thread __unsafe_unretained ShackDrvContext *tCurrent;
static __thread EGLSurface tBound;   // the surface tCurrent was made current with

static CGSize surfaceSize(ShackDrvContext *c, CGSize box) {
    return c->backingOn && c->backing[0] > 0 && c->backing[1] > 0 ? CGSizeMake(c->backing[0], c->backing[1]) : box;
}
static void layout(ShackDrvContext *c) {   // main thread
    CALayer *box = c->box; CAMetalLayer *layer = c->layer;
    if (!box || !layer) return;
    CGSize b = box.bounds.size, s = surfaceSize(c, b);
    if (s.width < 1 || s.height < 1) s = CGSizeMake(1, 1);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contentsScale = c->best ? box.contentsScale : 1;
    layer.bounds = (CGRect){CGPointZero, s};
    layer.position = CGPointMake(b.width / 2, b.height / 2);
    layer.affineTransform = CGAffineTransformMakeScale(b.width / s.width, b.height / s.height);
    [CATransaction commit];
    c->laidBox = b; c->laidSize = s;
}
// After a view resize or a backing size change. Never blocks a render thread on the main thread.
static void relayoutIfNeeded(ShackDrvContext *c) {
    CALayer *box = c->box;
    if (!box) return;
    CGSize b = box.bounds.size;
    if (CGSizeEqualToSize(b, c->laidBox) && CGSizeEqualToSize(surfaceSize(c, b), c->laidSize)) return;
    if (NSThread.isMainThread) layout(c);
    else dispatch_async(dispatch_get_main_queue(), ^{ layout(c); });
}

// The view's layer becomes `box`; the window surface goes in it.
void ShackGLDrvAttach(void *obj, CALayer *box, BOOL best) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)obj;
    if (c->surface) {
        if (tCurrent == c) { makeCurrent(NULL, c->ctx); tBound = NULL; }
        egl.DestroySurface(gDisplay, c->surface);
        c->surface = NULL;
    }
    [c->layer removeFromSuperlayer];
    c->box = box; c->best = best; c->layer = nil;
    if (!box) return;
    ShackMainSync(^{
        c->layer = [CAMetalLayer layer];
        c->layer.opaque = YES;
        [box addSublayer:c->layer];
        layout(c);
    });
    c->surface = egl.CreateWindowSurface(gDisplay, c->format->config, (__bridge void *)c->layer, NULL);
    NSLog(@"[ShackGL] metalgldrv window surface %.0fx%.0f: %@", c->laidSize.width, c->laidSize.height,
          c->surface ? @"made" : [NSString stringWithFormat:@"FAILED (EGL 0x%x)", egl.GetError()]);
    if (tCurrent == c && c->surface && makeCurrent(c->surface, c->ctx)) tBound = c->surface;
}

// ---- CGL ----------------------------------------------------------------------------------------------------------
static DrvError drv_ChoosePixelFormat(const int *attribs, void **pix, GLint *npix) {
    if (!pix) return kDrvBadAttribute;
    *pix = NULL;
    if (npix) *npix = 0;
    EGLint alpha = 8, depth = 0, stencil = 0, samples = 0;
    BOOL core = NO;
    for (const int *a = attribs; a && *a; a++) {
        switch (*a) {   // the attributes that take a value
        case 11: alpha = *++a; break;                 // kCGLPFAAlphaSize
        case 12: depth = *++a; break;                 // kCGLPFADepthSize
        case 13: stencil = *++a; break;               // kCGLPFAStencilSize
        case 56: samples = *++a; break;               // kCGLPFASamples
        case 99: core = *++a != 0x1000; break;        // kCGLPFAOpenGLProfile: Legacy or 3_2_Core / GL4_Core
        case 7: case 8: case 14: case 55: case 70: case 84: case 128: a++; break;   // ponytail: 8 bits per color channel
        }
    }
    EGLint want[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, alpha,
                     EGL_DEPTH_SIZE, depth, EGL_STENCIL_SIZE, stencil, EGL_SAMPLES, samples,
                     EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE};
    EGLConfig config = NULL; EGLint n = 0;
    if (!egl.ChooseConfig(gDisplay, want, &config, 1, &n) || n < 1) return kDrvBadPixelFormat;
    ShackDrvFormat *f = [ShackDrvFormat new];
    f->config = config; f->core = core;
    *pix = (__bridge_retained void *)f;
    if (npix) *npix = 1;
    return kDrvOK;
}
static DrvError drv_DestroyPixelFormat(void *pix) { if (pix) CFRelease(pix); return kDrvOK; }

static DrvError drv_CreateContext(void *pix, void *share, void **out) {
    if (!out) return kDrvBadAttribute;
    *out = NULL;
    if (!pix) return kDrvBadPixelFormat;
    ShackDrvFormat *f = (__bridge ShackDrvFormat *)pix;
    egl.BindAPI(EGL_OPENGL_API);
    // A core profile needs 3.2 or later asked for (both get the driver's 4.6)
    const EGLint core[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2,
                           EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    const EGLint compat[] = {EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT, EGL_NONE};
    const EGLint *attribs = f->core ? core : compat;
    EGLContext ctx = egl.CreateContext(gDisplay, f->config, share ? ((__bridge ShackDrvContext *)share)->ctx : NULL, attribs);
    NSLog(@"[ShackGL] metalgldrv %s context: %@", f->core ? "core" : "compatibility",
          ctx ? @"created" : [NSString stringWithFormat:@"FAILED (EGL 0x%x)", egl.GetError()]);
    if (!ctx) return kDrvBadContext;
    ShackDrvContext *c = [ShackDrvContext new];
    c->ctx = ctx; c->format = f; c->interval = 1;
    *out = (__bridge_retained void *)c;
    return kDrvOK;
}
static DrvError drv_DestroyContext(void *ctx) {
    if (!ctx) return kDrvBadContext;
    if (tCurrent == (__bridge ShackDrvContext *)ctx) { makeCurrent(NULL, NULL); tCurrent = nil; tBound = NULL; }
    CFRelease(ctx);
    return kDrvOK;
}
static DrvError drv_SetCurrentContext(void *ctx) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    // Feral's renderer sets the current context around nearly every GL call; on EGL each make-current flushes the driver
    // (Batman: a render pass per draw, 10 fps). The same context on the same surface again is nothing to do, as in CGL.
    if (c == tCurrent && (!c || tBound == c->surface)) return kDrvOK;
    if (!makeCurrent(c ? c->surface : NULL, c ? c->ctx : NULL)) return kDrvBadContext;
    tCurrent = c; tBound = c ? c->surface : NULL;
    if (c && c->surface) egl.SwapInterval(gDisplay, c->interval);
    return kDrvOK;
}
static void *drv_GetCurrentContext(void) { return (__bridge void *)tCurrent; }
static void *drv_GetPixelFormat(void *ctx) { return ctx ? (__bridge void *)((__bridge ShackDrvContext *)ctx)->format : NULL; }

void ShackGLPresented(void);   // ShackGL.m: the frame counter and the launch splash's first-frame notice
static DrvError drv_FlushDrawable(void *ctx) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    if (!c) return kDrvBadContext;
#ifndef SHACK_GLDRV_TEST
    ShackGLPresented();
#endif
    relayoutIfNeeded(c);
    if (!c->surface) { ((void (*)(void))dlsym(driver(), "glFlush"))(); return kDrvOK; }
    // A view attached while the context was current on another thread: bind the surface here.
    if (tCurrent == c && tBound != c->surface && makeCurrent(c->surface, c->ctx)) tBound = c->surface;
    return egl.SwapBuffers(gDisplay, c->surface) ? kDrvOK : kDrvBadDrawable;
}
static DrvError drv_ClearDrawable(void *ctx) { if (ctx) ShackGLDrvAttach(ctx, nil, NO); return ctx ? kDrvOK : kDrvBadContext; }
static DrvError drv_UpdateContext(void *ctx) { if (ctx) relayoutIfNeeded((__bridge ShackDrvContext *)ctx); return ctx ? kDrvOK : kDrvBadContext; }

static DrvError drv_SetParameter(void *ctx, int pname, const GLint *params) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    if (!c) return kDrvBadContext;
    if (!params) return kDrvBadAttribute;
    if (pname == kSwapInterval) {
        c->interval = params[0];
        if (tCurrent == c && tBound) egl.SwapInterval(gDisplay, c->interval);
    } else if (pname == kSurfaceBackingSize) {
        c->backing[0] = params[0]; c->backing[1] = params[1];
        relayoutIfNeeded(c);
    }   // ponytail: surface order/opacity and the rest are not applied
    return kDrvOK;
}
static DrvError drv_GetParameter(void *ctx, int pname, GLint *params) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    if (!c) return kDrvBadContext;
    if (!params) return kDrvBadAttribute;
    if (pname == kSwapInterval) params[0] = c->interval;
    else if (pname == kSurfaceBackingSize) { params[0] = c->backing[0]; params[1] = c->backing[1]; }
    else params[0] = 0;
    return kDrvOK;
}
static DrvError setEnabled(void *ctx, int pname, BOOL on) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    if (!c) return kDrvBadContext;
    if (pname == kEnableSurfaceBackingSize) { c->backingOn = on; relayoutIfNeeded(c); }   // the rest: nothing to do on Metal
    return kDrvOK;
}
static DrvError drv_Enable(void *ctx, int pname) { return setEnabled(ctx, pname, YES); }
static DrvError drv_Disable(void *ctx, int pname) { return setEnabled(ctx, pname, NO); }
static DrvError drv_IsEnabled(void *ctx, int pname, GLint *on) {
    ShackDrvContext *c = (__bridge ShackDrvContext *)ctx;
    if (!c || !on) return kDrvBadContext;
    *on = pname == kEnableSurfaceBackingSize && c->backingOn;
    return kDrvOK;
}

// The game's gl* functions (all the driver's: nothing mixes with the ES layer) and its CGL context functions.
void *ShackGLDrvProc(const char *name) {
    void *lib = driver();
    if (!lib) return NULL;
    if (strncmp(name, "CGL", 3)) return dlsym(lib, name);
    static const struct { const char *name; void *fn; } cgl[] = {
        {"CGLChoosePixelFormat", drv_ChoosePixelFormat}, {"CGLDestroyPixelFormat", drv_DestroyPixelFormat},
        {"CGLReleasePixelFormat", drv_DestroyPixelFormat}, {"CGLCreateContext", drv_CreateContext},
        {"CGLDestroyContext", drv_DestroyContext}, {"CGLReleaseContext", drv_DestroyContext},
        {"CGLSetCurrentContext", drv_SetCurrentContext}, {"CGLGetCurrentContext", drv_GetCurrentContext},
        {"CGLGetPixelFormat", drv_GetPixelFormat}, {"CGLFlushDrawable", drv_FlushDrawable}, {"CGLClearDrawable", drv_ClearDrawable},
        {"CGLUpdateContext", drv_UpdateContext}, {"CGLSetParameter", drv_SetParameter}, {"CGLGetParameter", drv_GetParameter},
        {"CGLEnable", drv_Enable}, {"CGLDisable", drv_Disable}, {"CGLIsEnabled", drv_IsEnabled},
    };
    for (size_t i = 0; i < sizeof cgl / sizeof *cgl; i++) if (!strcmp(name, cgl[i].name)) return cgl[i].fn;
    return NULL;   // renderer info, CGLLockContext, CGLGetShareGroup...: libShackOpenGL's answers
}

#ifndef SHACK_GLDRV_TEST
// ---- NSOpenGLContext / NSOpenGLPixelFormat -------------------------------------------------------------------------
// While the driver is on, +alloc of the two AppKit shim classes (ShackGL.m) gives these subclasses, which run on the CGL
// above; a CGLContextObj is the CGL context, as on a Mac.
@interface NSOpenGLPixelFormat : NSObject @end
@interface NSOpenGLContext : NSObject + (id)currentContext; + (void)clearCurrentContext; @end

@interface ShackDrvNSFormat : NSOpenGLPixelFormat @end
@implementation ShackDrvNSFormat { @public void *_pix; }
- (instancetype)initWithAttributes:(const uint32_t *)attribs {
    int list[128]; size_t n = 0;   // NSOpenGL's attributes are CGL's
    for (const uint32_t *a = attribs; a && *a && n + 3 < 128;) {
        uint32_t k = *a++;
        list[n++] = (int)k;
        switch (k) { case 7: case 8: case 11: case 12: case 13: case 14: case 55: case 56: case 70: case 84: case 99: case 128: list[n++] = (int)*a++; }
    }
    list[n] = 0;
    GLint count = 0;
    if (!(self = [super init]) || drv_ChoosePixelFormat(list, &_pix, &count)) return nil;
    return self;
}
- (instancetype)init { const uint32_t a[] = {5, 73, 0}; return [self initWithAttributes:a]; }   // double buffer, accelerated
- (void *)CGLPixelFormatObj { return _pix; }
- (void)dealloc { if (_pix) CFRelease(_pix); }
@end

static NSMapTable *gContexts;   // CGL context -> its NSOpenGLContext (weak)
@interface ShackDrvNSContext : NSOpenGLContext @end
@implementation ShackDrvNSContext { void *_cgl; NSOpenGLPixelFormat *_format; __weak NSView *_view; }
- (instancetype)initWithShackCGL:(void *)ctx format:(NSOpenGLPixelFormat *)format {
    if (!ctx || !(self = [super init])) return nil;
    _cgl = ctx; _format = format;
    @synchronized(ShackDrvNSContext.class) {
        if (!gContexts) gContexts = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                          valueOptions:NSPointerFunctionsWeakMemory];
        [gContexts setObject:self forKey:(__bridge id)ctx];
    }
    return self;
}
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share {
    void *pix = [format isKindOfClass:ShackDrvNSFormat.class] ? ((ShackDrvNSFormat *)format)->_pix : NULL;
    void *with = [share isKindOfClass:ShackDrvNSContext.class] ? ((ShackDrvNSContext *)share)->_cgl : NULL, *ctx = NULL;
    return drv_CreateContext(pix, with, &ctx) ? nil : [self initWithShackCGL:ctx format:format];
}
- (instancetype)initWithCGLContextObj:(void *)ctx {
    @synchronized(ShackDrvNSContext.class) { id known = [gContexts objectForKey:(__bridge id)ctx]; if (known) return known; }
    return ctx ? [self initWithShackCGL:(void *)CFRetain(ctx) format:nil] : nil;
}
- (void)dealloc {
    @synchronized(ShackDrvNSContext.class) { if ([gContexts objectForKey:(__bridge id)_cgl] == self) [gContexts removeObjectForKey:(__bridge id)_cgl]; }
    drv_DestroyContext(_cgl);
}
- (void *)CGLContextObj { return _cgl; }
- (NSOpenGLPixelFormat *)pixelFormat { return _format; }
- (NSView *)view { return _view; }
- (void)setView:(NSView *)view {
    _view = view;
    if (!view) { ShackGLDrvAttach(_cgl, nil, NO); return; }
    __block CALayer *box;
    ShackMainSync(^{ box = [CALayer layer]; });
    view.layer = box;   // NSView.m attaches it under its UIView, sized to the view
    SEL bestSel = NSSelectorFromString(@"wantsBestResolutionOpenGLSurface");   // NSView.m
    BOOL best = [view respondsToSelector:bestSel] && ((BOOL (*)(id, SEL))objc_msgSend)(view, bestSel);
    ShackGLDrvAttach(_cgl, box, best);
}
- (void)clearDrawable { _view = nil; ShackGLDrvAttach(_cgl, nil, NO); }
- (void)makeCurrentContext { drv_SetCurrentContext(_cgl); }
- (void)flushBuffer { drv_FlushDrawable(_cgl); }
- (void)update { drv_UpdateContext(_cgl); }
- (void)setValues:(const GLint *)vals forParameter:(NSInteger)param { drv_SetParameter(_cgl, (int)param, vals); }
- (void)getValues:(GLint *)vals forParameter:(NSInteger)param { drv_GetParameter(_cgl, (int)param, vals); }
@end

// +allocWithZone: hands back an owned (+1) object (ARC: the replacements say so, or the guest's release frees it twice).
typedef id (*AllocIMP)(id, SEL, NSZone *) __attribute__((ns_returns_retained));
static IMP gContextAlloc, gFormatAlloc, gCurrent, gClearCurrent;
static id context_alloc(id self, SEL _cmd, NSZone *zone) __attribute__((ns_returns_retained)) {
    if (self == NSOpenGLContext.class && driver()) return [ShackDrvNSContext allocWithZone:zone];
    return ((AllocIMP)gContextAlloc)(self, _cmd, zone);
}
static id format_alloc(id self, SEL _cmd, NSZone *zone) __attribute__((ns_returns_retained)) {
    if (self == NSOpenGLPixelFormat.class && driver()) return [ShackDrvNSFormat allocWithZone:zone];
    return ((AllocIMP)gFormatAlloc)(self, _cmd, zone);
}
static id current_context(id self, SEL _cmd) {
    if (!driver()) return ((id (*)(id, SEL))gCurrent)(self, _cmd);
    void *now = drv_GetCurrentContext();
    if (!now) return nil;
    @synchronized(ShackDrvNSContext.class) { return [gContexts objectForKey:(__bridge id)now]; }
}
static void clear_current(id self, SEL _cmd) {
    if (!driver()) { ((void (*)(id, SEL))gClearCurrent)(self, _cmd); return; }
    drv_SetCurrentContext(NULL);
}
static IMP replace_class_method(Class cls, SEL sel, IMP imp) {   // on the metaclass itself, so NSObject's stays
    Method m = class_getClassMethod(cls, sel);
    IMP original = method_getImplementation(m);
    if (!class_addMethod(object_getClass(cls), sel, imp, method_getTypeEncoding(m))) original = method_setImplementation(m, imp);
    return original;
}
__attribute__((constructor)) static void installDriverClasses(void) {
    gContextAlloc = replace_class_method(NSOpenGLContext.class, @selector(allocWithZone:), (IMP)context_alloc);
    gFormatAlloc = replace_class_method(NSOpenGLPixelFormat.class, @selector(allocWithZone:), (IMP)format_alloc);
    gCurrent = replace_class_method(NSOpenGLContext.class, @selector(currentContext), (IMP)current_context);
    gClearCurrent = replace_class_method(NSOpenGLContext.class, @selector(clearCurrentContext), (IMP)clear_current);
}
#endif
