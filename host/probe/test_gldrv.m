// Mac check of the CGL-over-EGL adapter (shims/AppKit/ShackGLDrv.m) on metalgldrv's macOS build, which has EGL too
// (cmake -G Ninja -B build-mac && ninja -C build-mac in a metalgldrv checkout):
//   clang -fobjc-arc -DSHACK_GLDRV_TEST shims/AppKit/ShackGLDrv.m host/probe/test_gldrv.m -framework Foundation \
//     -framework QuartzCore -framework CoreGraphics -Wl,-rpath,<metalgldrv>/build-mac -o /tmp/t && /tmp/t
// expect "gldrv ok". A context gets a window surface in a layer of the view, draws, presents, and follows the CGL surface
// backing size (Batman: 1600x900 stretched over the window).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <assert.h>

typedef int Err;   // CGLError
void *ShackGLDrvProc(const char *name);
void ShackGLDrvAttach(void *ctx, CALayer *box, BOOL best);
int ShackGLDrvMakeCurrentCalls(void);   // eglMakeCurrent calls so far (SHACK_GLDRV_TEST)

int main(void) { @autoreleasepool {
    setenv("SHACK_GL", "metalgldrv", 1);
    Err (*choose)(const int *, void **, int *) = ShackGLDrvProc("CGLChoosePixelFormat");
    Err (*create)(void *, void *, void **) = ShackGLDrvProc("CGLCreateContext");
    Err (*setCurrent)(void *) = ShackGLDrvProc("CGLSetCurrentContext");
    void *(*getCurrent)(void) = ShackGLDrvProc("CGLGetCurrentContext");
    Err (*flush)(void *) = ShackGLDrvProc("CGLFlushDrawable");
    Err (*setParam)(void *, int, const int *) = ShackGLDrvProc("CGLSetParameter");
    Err (*enable)(void *, int) = ShackGLDrvProc("CGLEnable");
    void (*clearColor)(float, float, float, float) = ShackGLDrvProc("glClearColor");
    void (*clear)(unsigned) = ShackGLDrvProc("glClear");
    void (*readPixels)(int, int, int, int, unsigned, unsigned, void *) = ShackGLDrvProc("glReadPixels");
    void (*getIntegerv)(unsigned, int *) = ShackGLDrvProc("glGetIntegerv");
    assert(choose && create && setCurrent && getCurrent && flush && setParam && enable && clearColor && readPixels);

    const int attribs[] = {5, 12, 24, 0};   // double buffer, depth 24
    void *pix = NULL, *ctx = NULL; int n = 0;
    assert(choose(attribs, &pix, &n) == 0 && pix && n == 1);
    assert(create(pix, NULL, &ctx) == 0 && ctx);
    CALayer *box = [CALayer layer]; box.bounds = CGRectMake(0, 0, 40, 20);
    ShackGLDrvAttach(ctx, box, NO);
    assert(setCurrent(ctx) == 0 && getCurrent() == ctx);
    // Feral's renderer sets the current context around nearly every GL call: the same one again must not reach EGL, where
    // each eglMakeCurrent flushes (Batman: a render pass per draw, 10 fps)
    // ...and releasing it (CGLSetCurrentContext(NULL), its unlock) must not flush either: no release flush, as in CGL
    int release = -1; getIntegerv(0x82FB /* GL_CONTEXT_RELEASE_BEHAVIOR */, &release);
    printf("release behavior 0x%x\n", release);
    assert(release == 0 /* GL_NONE */);
    int calls = ShackGLDrvMakeCurrentCalls();
    for (int i = 0; i < 100; i++) assert(setCurrent(ctx) == 0);
    assert(ShackGLDrvMakeCurrentCalls() == calls);
    CAMetalLayer *layer = (CAMetalLayer *)box.sublayers.firstObject;
    assert([layer isKindOfClass:CAMetalLayer.class]);

    int viewport[4] = {0}; getIntegerv(0x0BA2 /* GL_VIEWPORT */, viewport);
    clearColor(1, 0, 0, 1); clear(0x4000 /* GL_COLOR_BUFFER_BIT */);
    unsigned char px[4] = {0}; readPixels(20, 10, 1, 1, 0x1908 /* GL_RGBA */, 0x1401 /* GL_UNSIGNED_BYTE */, px);
    assert(flush(ctx) == 0);
    printf("surface: viewport %dx%d, pixel %d %d %d, drawable %.0fx%.0f\n", viewport[2], viewport[3], px[0], px[1], px[2],
           layer.drawableSize.width, layer.drawableSize.height);
    assert(viewport[2] == 40 && viewport[3] == 20 && px[0] == 255 && px[1] == 0);   // points, as Apple's GL without best resolution
    assert(layer.drawableSize.width == 40 && layer.drawableSize.height == 20);

    const int backing[2] = {64, 32};
    assert(setParam(ctx, 304, backing) == 0 && enable(ctx, 305) == 0);   // kCGLCPSurfaceBackingSize, kCGLCESurfaceBackingSize
    assert(flush(ctx) == 0);
    printf("backing: layer %.0fx%.0f scaled %.3f %.3f, drawable %.0fx%.0f\n", layer.bounds.size.width, layer.bounds.size.height,
           layer.affineTransform.a, layer.affineTransform.d, layer.drawableSize.width, layer.drawableSize.height);
    assert(layer.bounds.size.width == 64 && layer.bounds.size.height == 32);
    assert(fabs(layer.affineTransform.a - 40.0 / 64) < 1e-6 && fabs(layer.affineTransform.d - 20.0 / 32) < 1e-6);   // stretched over the view
    assert(layer.drawableSize.width == 64 && layer.drawableSize.height == 32);
    // kCGLPFAOpenGLProfile kCGLOGLPVersion_3_2_Core: a core context (GL_CONTEXT_PROFILE_MASK core bit)
    const int coreAttribs[] = {5, 99, 0x3200, 0};
    void *corePix = NULL, *core = NULL;
    assert(choose(coreAttribs, &corePix, &n) == 0 && create(corePix, NULL, &core) == 0 && setCurrent(core) == 0);
    int mask = 0; getIntegerv(0x9126 /* GL_CONTEXT_PROFILE_MASK */, &mask);
    printf("core context: profile mask %d\n", mask);
    assert(mask == 1);
    assert(setCurrent(NULL) == 0 && getCurrent() == NULL);
    puts("gldrv ok");
}}
