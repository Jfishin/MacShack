// Desktop OpenGL for GLFW guests (raylib: Sly Cooper) on OpenGL ES 3, opt-in with SHACK_OPENGL=1
// (`--shack-env=SHACK_OPENGL=1` in the game's .args). Without it every pixel format and context fails to exist, so
// SDL2 and Unity keep taking their Metal paths. An EAGL context renders into a CAEAGLLayer on the view; framebuffer
// 0 means that layer. GLFW finds the gl* functions through the OpenGL bundle, which ShackHooks.m routes to
// ShackGLGetProcAddress. ponytail: only what raylib's GL 3.3 path needs is translated (GLSL 330 → 300 es, double
// depth calls, the RGBA swizzle, FBO 0); add translations when another guest's GL log shows errors.
#define GLES_SILENCE_DEPRECATION 1
#import "ShackAppKit.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdatomic.h>

static BOOL enabled(void) { const char *e = getenv("SHACK_OPENGL"); return e && e[0] == '1'; }
static __thread GLuint tLayerFBO;   // the current context's layer framebuffer: what the guest's framebuffer 0 means

@interface NSOpenGLPixelFormat : NSObject @end
@implementation NSOpenGLPixelFormat
SHACK_SAFETY_NET
- (instancetype)initWithAttributes:(const uint32_t *)attribs { return enabled() ? [super init] : nil; }
@end

@interface NSOpenGLContext : NSObject @end
@implementation NSOpenGLContext { EAGLContext *_ctx; CAEAGLLayer *_layer; NSView *_view; GLuint _fbo, _color, _depth; CGSize _size; GLint _interval; NSOpenGLPixelFormat *_format; }
SHACK_SAFETY_NET
static __thread __unsafe_unretained NSOpenGLContext *tCurrent;
+ (NSOpenGLContext *)currentContext { return tCurrent; }
+ (void)clearCurrentContext { tCurrent = nil; tLayerFBO = 0; [EAGLContext setCurrentContext:nil]; }
- (instancetype)initWithFormat:(NSOpenGLPixelFormat *)format shareContext:(NSOpenGLContext *)share {
    if (!enabled()) { NSLog(@"[ShackAppKit] NSOpenGLContext requested; OpenGL is off (SHACK_OPENGL=1 enables it)"); return nil; }
    if (!format || !(self = [super init])) return nil;
    _ctx = share ? [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:share->_ctx.sharegroup]
                 : [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    NSLog(@"[ShackAppKit] NSOpenGLContext on OpenGL ES 3: %@", _ctx ? @"created" : @"FAILED");
    _format = format;
    return _ctx ? self : nil;
}
// A CGLContextObj here is the NSOpenGLContext itself (ShackCGL* below), so wrapping one returns it.
- (instancetype)initWithCGLContextObj:(void *)ctx { return ctx ? (__bridge NSOpenGLContext *)ctx : nil; }
- (void *)CGLContextObj { return (__bridge void *)self; }
- (NSOpenGLPixelFormat *)pixelFormat { return _format; }
- (NSView *)view { return _view; }
- (void)setView:(NSView *)view {
    __block CAEAGLLayer *layer;
    ShackMainSync(^{
        layer = [CAEAGLLayer layer];
        layer.opaque = YES;
        layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    });
    _view = view; _layer = layer; _size = CGSizeZero;
    view.layer = layer;   // NSView attaches it (sized, scaled) under its UIView; storage follows at the next current/flush
}
// Drawable storage follows the layer's pixel size; checked at makeCurrent and after every flush (resizes, late attach).
- (void)fitLayer {
    CGSize px = CGSizeMake(_layer.bounds.size.width * _layer.contentsScale, _layer.bounds.size.height * _layer.contentsScale);
    if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(px, _size)) return;
    GLint fb, rb, w = 0, h = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb); glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    if (!_fbo) { glGenFramebuffers(1, &_fbo); glGenRenderbuffers(1, &_color); glGenRenderbuffers(1, &_depth); }
    glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
    glBindRenderbuffer(GL_RENDERBUFFER, _color);
    [_ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:_layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _color);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
    glBindRenderbuffer(GL_RENDERBUFFER, _depth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);   // desktop default framebuffers have depth+stencil
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depth);
    NSLog(@"[ShackAppKit] GL layer framebuffer %dx%d: 0x%x", w, h, glCheckFramebufferStatus(GL_FRAMEBUFFER));
    static dispatch_once_t once; dispatch_once(&once, ^{ NSLog(@"[ShackAppKit] GL %s, extensions: %s", glGetString(GL_RENDERER), glGetString(GL_EXTENSIONS)); });
    _size = px; tLayerFBO = _fbo;
    glBindFramebuffer(GL_FRAMEBUFFER, fb ? (GLuint)fb : _fbo);   // the guest's 0 was "no FBO yet": now it is the layer
    glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)rb);
}
- (void)makeCurrentContext {
    [EAGLContext setCurrentContext:_ctx]; tCurrent = self; tLayerFBO = _fbo;
    if (_layer) [self fitLayer];
}
static _Atomic unsigned gGLFrames;
unsigned ShackGLTakeFrameCount(void) { return atomic_exchange(&gGLFrames, 0); }   // presents since the last call (ShackWatch)
- (void)flushBuffer {
    atomic_fetch_add(&gGLFrames, 1);
    if (_size.width) {
        GLint rb; glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
        glBindRenderbuffer(GL_RENDERBUFFER, _color);
        [_ctx presentRenderbuffer:GL_RENDERBUFFER];
        glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)rb);
        static atomic_bool presented;   // the launch splash (GameOverlay.swift) waits for the game to draw, as for Metal
        if (!atomic_exchange(&presented, true)) dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:@"ShackGameFirstFrame" object:nil];
        });
    }
    [self fitLayer];
}
- (void)update {}   // GLFW calls it on resize from the app thread; fitLayer notices the new size at the next flush
enum { NSOpenGLContextParameterSwapInterval = 222 };
// ponytail: the swap interval is stored, not applied; Core Animation composites every present without tearing.
- (void)setValues:(const GLint *)vals forParameter:(NSInteger)param { if (param == NSOpenGLContextParameterSwapInterval && vals) _interval = *vals; }
- (void)getValues:(GLint *)vals forParameter:(NSInteger)param { if (vals) *vals = param == NSOpenGLContextParameterSwapInterval ? _interval : 0; }
@end

// Godot 3's content view subclasses it and hands it its own context; one made on demand if asked.
@interface NSOpenGLView : NSView @end
@implementation NSOpenGLView { NSOpenGLContext *_ctx; NSOpenGLPixelFormat *_format; }
- (instancetype)initWithFrame:(NSRect)r pixelFormat:(NSOpenGLPixelFormat *)f { if ((self = [super initWithFrame:r])) _format = f; return self; }
+ (NSOpenGLPixelFormat *)defaultPixelFormat { return [[NSOpenGLPixelFormat alloc] initWithAttributes:NULL]; }
- (NSOpenGLPixelFormat *)pixelFormat { return _format; }
- (void)setPixelFormat:(NSOpenGLPixelFormat *)f { _format = f; }
- (NSOpenGLContext *)openGLContext {
    if (!_ctx) {
        _ctx = [[NSOpenGLContext alloc] initWithFormat:_format ?: NSOpenGLView.defaultPixelFormat shareContext:nil];
        [_ctx setView:self]; [self prepareOpenGL];
    }
    return _ctx;
}
- (void)setOpenGLContext:(NSOpenGLContext *)c { _ctx = c; [c setView:self]; }
- (void)clearGLContext { _ctx = nil; }
- (void)prepareOpenGL {}
- (void)reshape {}
- (void)update { [_ctx update]; }
@end

// ShackGLLegacy.m: fixed-function client arrays, ARB shader objects and GLSL 1.x for older GL games.
const GLubyte *ShackGLLegacyExtensions(void);
NSString *ShackGLLegacySource(NSString *src, GLenum type);
void *ShackGLLegacyProc(const char *name);

// Desktop entry points ES lacks or spells differently.
static const GLubyte *shack_glGetString(GLenum name) {
    // glad reads the version to decide which entry points to load: desktop 3.3 is what the guest asked for.
    if (name == GL_VERSION) return (const GLubyte *)"3.3 MacShack (OpenGL ES 3.0)";
    if (name == GL_SHADING_LANGUAGE_VERSION) return (const GLubyte *)"3.30";
    if (name == GL_EXTENSIONS) return ShackGLLegacyExtensions();   // desktop names ShackGLLegacy.m stands behind
    return glGetString(name);
}
static void shack_glShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {
    size_t total = 0;
    for (GLsizei i = 0; i < count; i++) total += lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
    // GLSL ES has no default precision for these samplers; desktop GLSL needs none (Godot 3 declares sampler2DArray).
    static const char es[] = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
        "precision highp sampler3D;\nprecision highp samplerCube;\nprecision highp sampler2DArray;\nprecision highp sampler2DShadow;\n"
        "precision highp samplerCubeShadow;\nprecision highp sampler2DArrayShadow;\nprecision highp isampler2D;\n"
        "precision highp usampler2D;\nprecision highp isampler3D;\nprecision highp usampler3D;\nprecision highp isampler2DArray;\n"
        "precision highp usampler2DArray;\nprecision highp isamplerCube;\nprecision highp usamplerCube;\n";
    char *src = malloc(total + sizeof es), *p = src;
    for (GLsizei i = 0; i < count; i++) {
        size_t n = lengths && lengths[i] >= 0 ? (size_t)lengths[i] : strlen(strings[i]);
        memcpy(p, strings[i], n); p += n;
    }
    *p = 0;
    GLint type = 0; glGetShaderiv(shader, GL_SHADER_TYPE, &type);
    NSString *legacy = ShackGLLegacySource(@(src), (GLenum)type);   // GLSL 1.x (no #version, or below 130)
    if (legacy) {
        const GLchar *l = legacy.UTF8String;
        glShaderSource(shader, 1, &l, NULL);
        free(src);
        return;
    }
    // GLSL 3.30 and GLSL ES 3.00 share what raylib's shaders use; ES needs its own version line and precisions.
    char *v = strstr(src, "#version"), *eol = v ? strchr(v, '\n') : NULL;
    if (v && eol && !memmem(v, (size_t)(eol - v), " es", 3)) {
        memmove(v + sizeof es - 1, eol + 1, strlen(eol + 1) + 1);
        memcpy(v, es, sizeof es - 1);
        // Desktop extension lines (Unity's GLSL 150: GL_ARB_explicit_attrib_location : require) are errors in ES,
        // whose 3.00 core already has what they enable; blank them in place.
        for (char *x = strstr(src, "#extension GL_ARB_"); x; x = strstr(x, "#extension GL_ARB_"))
            for (; *x && *x != '\n'; x++) *x = ' ';
    }
    // Godot 3's desktop prelude defines GLES_OVER_GL, and its shaders branch on it; without it they take the path
    // Godot itself runs on mobile GLES3.
    static const char godot[] = "#define GLES_OVER_GL\n";
    char *g = strstr(src, godot);
    if (g) memmove(g, g + sizeof godot - 1, strlen(g + sizeof godot - 1) + 1);
    const GLchar *s = src;
    glShaderSource(shader, 1, &s, NULL);
    free(src);
}
// CGL for Unity's desktop GL renderer (Subnautica and Aragami ship only GLSL 150/410 shaders), over the same
// NSOpenGLContext: a CGLContextObj is a retained NSOpenGLContext, a CGLPixelFormatObj a retained NSOpenGLPixelFormat.
// shims/OpenGL/ShackOpenGL.c forwards the CGL entry points here. ponytail: one renderer, fixed capability answers.
enum { kShackCGLNoError = 0, kShackCGLBadPixelFormat = 10002, kShackCGLBadContext = 10004 };
int ShackCGLChoosePixelFormat(const int *attribs, void **pix, GLint *npix) {
    NSOpenGLPixelFormat *f = [[NSOpenGLPixelFormat alloc] initWithAttributes:NULL];
    if (pix) *pix = f ? (__bridge_retained void *)f : NULL;
    if (npix) *npix = f ? 1 : 0;
    return f ? kShackCGLNoError : kShackCGLBadPixelFormat;
}
int ShackCGLCreateContext(void *pix, void *share, void **ctx) {
    NSOpenGLContext *c = pix ? [[NSOpenGLContext alloc] initWithFormat:(__bridge NSOpenGLPixelFormat *)pix
                                                           shareContext:(__bridge NSOpenGLContext *)share] : nil;
    if (ctx) *ctx = c ? (__bridge_retained void *)c : NULL;
    return c ? kShackCGLNoError : kShackCGLBadContext;
}
void ShackCGLRelease(void *obj) { if (obj) CFRelease(obj); }
int ShackCGLSetCurrentContext(void *ctx) {
    if (ctx) [(__bridge NSOpenGLContext *)ctx makeCurrentContext]; else [NSOpenGLContext clearCurrentContext];
    return kShackCGLNoError;
}
void *ShackCGLGetCurrentContext(void) { return (__bridge void *)[NSOpenGLContext currentContext]; }
void *ShackCGLGetPixelFormat(void *ctx) { return ctx ? (__bridge void *)[(__bridge NSOpenGLContext *)ctx pixelFormat] : NULL; }
int ShackCGLFlushDrawable(void *ctx) {
    if (!ctx) return kShackCGLBadContext;
    [(__bridge NSOpenGLContext *)ctx flushBuffer];
    return kShackCGLNoError;
}
int ShackCGLSetParameter(void *ctx, int pname, const GLint *params) {
    if (!ctx) return kShackCGLBadContext;
    if (pname == 222 && params) [(__bridge NSOpenGLContext *)ctx setValues:params forParameter:NSOpenGLContextParameterSwapInterval];   // kCGLCPSwapInterval
    return kShackCGLNoError;
}
// CGLDescribeRenderer: kCGLRP properties of one accelerated, online renderer with GL 4.x-class memory figures.
int ShackCGLDescribeRenderer(int prop, GLint *value) {
    GLint v = 0;
    switch (prop) {
    case 70: v = 0x00024000; break;                       // kCGLRPRendererID (an Apple GPU id)
    case 73: case 37: case 80: case 78: case 83: case 129: v = 1; break;   // Accelerated, (37), Window, MPSafe, Compliant, Online
    case 122: case 123: v = 1; break;                     // GPUVertProcCapable, GPUFragProcCapable
    case 84: v = 0xff; break;                             // kCGLRPDisplayMask
    case 128: v = 1; break;                               // kCGLRPRendererCount
    case 131: case 132: v = 2048; break;                  // Video/TextureMemoryMegabytes
    case 120: case 121: v = 0x7fffffff; break;            // Video/TextureMemory (bytes, clamped)
    case 133: v = 4; break;                               // kCGLRPMajorGLVersion
    }
    if (value) *value = v;
    return kShackCGLNoError;
}
int ShackCGLEnabled(void) { return enabled(); }

void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {
    shack_glShaderSource(shader, count, strings, lengths);   // glShaderSourceARB (ShackGLLegacy.m)
}
static void shack_glClearDepth(double d) { glClearDepthf((GLfloat)d); }
static void shack_glDepthRange(double n, double f) { glDepthRangef((GLfloat)n, (GLfloat)f); }
static void shack_glBindFramebuffer(GLenum target, GLuint fb) { glBindFramebuffer(target, fb ? fb : tLayerFBO); }
static void shack_glTexParameteriv(GLenum target, GLenum pname, const GLint *params) {
    if (pname != 0x8E46) { glTexParameteriv(target, pname, params); return; }   // GL_TEXTURE_SWIZZLE_RGBA: ES has only R/G/B/A
    for (GLenum i = 0; i < 4; i++) glTexParameteri(target, GL_TEXTURE_SWIZZLE_R + i, params[i]);
}

GLenum ShackBCStorageFormat(GLenum f);
int ShackBCCompressedTexImage2D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLsizei size, const void *data);
int ShackBCCompressedTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLsizei size, const void *data);
int ShackBCCompressedTexImage3D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLsizei depth, GLsizei size, const void *data);
int ShackBCCompressedTexSubImage3D(GLenum t, GLint l, GLint x, GLint y, GLint z, GLsizei w, GLsizei h, GLsizei depth, GLenum f, GLsizei size, const void *data);

// Diagnostics for framebuffers ES rejects: the internal format each texture/renderbuffer was allocated with (ES 3.0
// cannot query it), logged with the attachments of an incomplete framebuffer.
static GLenum gTexFormat[8192], gRBFormat[8192];
static void noteTex(GLenum target, GLenum f) {
    GLenum binding = target == GL_TEXTURE_2D ? GL_TEXTURE_BINDING_2D : target == GL_TEXTURE_3D ? GL_TEXTURE_BINDING_3D
                   : target == GL_TEXTURE_2D_ARRAY ? GL_TEXTURE_BINDING_2D_ARRAY : GL_TEXTURE_BINDING_CUBE_MAP;
    GLint t = 0; glGetIntegerv(binding, &t); if (t > 0 && t < 8192) gTexFormat[t] = f;
}
// iOS renders to 16-bit floats only (EXT_color_buffer_half_float): single/dual-channel 32-bit float targets (Godot 3's
// exposure and luminance buffers) become 16-bit. RGBA32F stays: it holds data (skeletons) and is not rendered to.
static GLint renderable(GLint f) { return f == GL_R32F ? GL_R16F : f == GL_RG32F ? GL_RG16F : f; }
// SHACK_GL_TEXLOG=1: each 2D upload and the unpack state, written before the call (a bad guest buffer faults inside it).
static void texLog(const char *what, GLenum t, GLint l, GLint f, GLsizei w, GLsizei h, GLenum fmt, GLenum type, const void *d) {
    static int on = -1;
    if (on < 0) on = getenv("SHACK_GL_TEXLOG") != NULL;
    if (!on) return;
    GLint align = 0, row = 0, skipP = 0, skipR = 0, pbo = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    fprintf(stderr, "[ShackGL] %s t=%#x l=%d f=%#x %dx%d fmt=%#x type=%#x d=%p align=%d row=%d skip=%d,%d pbo=%d\n",
            what, t, l, f, w, h, fmt, type, d, align, row, skipP, skipR, pbo);
}
// Bytes per pixel of a client-memory upload, 0 when unknown.
static size_t pixelBytes(GLenum fmt, GLenum type) {
    size_t comps = fmt == GL_RGBA || fmt == 0x80E1 || fmt == 0x8D99 ? 4 : fmt == GL_RGB || fmt == 0x80E0 || fmt == 0x8D98 ? 3 : fmt == GL_RG || fmt == GL_LUMINANCE_ALPHA || fmt == 0x8228 ? 2
                 : fmt == GL_RED || fmt == GL_LUMINANCE || fmt == GL_ALPHA || fmt == 0x8D94 ? 1 : 0;
    if (type == 0x8035 || type == 0x8367) return comps == 4 ? 4 : 0;   // GL_UNSIGNED_INT_8_8_8_8 and _REV
    switch (type) {
    case GL_UNSIGNED_BYTE: case GL_BYTE: return comps;
    case GL_UNSIGNED_SHORT: case GL_SHORT: case 0x140B: return comps * 2;   // 0x140B GL_HALF_FLOAT
    case GL_FLOAT: case GL_UNSIGNED_INT: case GL_INT: return comps * 4;
    case 0x8033: case 0x8034: case 0x8363: return 2;   // packed 4444 / 5551 / 565
    default: return 0;
    }
}
static BOOL readable(const void *p) { char c; vm_size_t n = 0; return vm_read_overwrite(mach_task_self(), (vm_address_t)p, 1, (vm_address_t)&c, &n) == KERN_SUCCESS; }
// Unity asks for a mip chain's tail past the end of the buffer it filled (the loading screen's 1912x880 RGB image,
// which reads adjacent heap on a Mac); AArchX's heap has a guard there and the driver faults. A buffer whose end is
// unreadable is copied, with what is readable, into a zero-padded one. Returns the buffer to free, or NULL.
static void *guardedSource(GLsizei w, GLsizei h, GLenum fmt, GLenum type, const void **d) {
    if (!*d || w <= 0 || h <= 0) return NULL;
    size_t bpp = pixelBytes(fmt, type);
    GLint align = 4, row = 0, skipP = 0, skipR = 0, pbo = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (!bpp || row || skipP || skipR || pbo || align < 1) return NULL;
    size_t stride = ((size_t)w * bpp + (size_t)align - 1) / (size_t)align * (size_t)align, size = stride * (size_t)(h - 1) + (size_t)w * bpp;
    const char *p = *d;
    if (readable(p + size - 1)) return NULL;
    size_t page = 16384, ok = 0;
    for (size_t at = 0; at < size; ) {   // the readable prefix, a page at a time
        size_t next = ((uintptr_t)(p + at) / page + 1) * page - (uintptr_t)p;
        if (!readable(p + at)) break;
        ok = next < size ? next : size; at = next;
    }
    static atomic_int said;
    if (atomic_fetch_add(&said, 1) < 8) NSLog(@"[ShackGL] upload %dx%d reads %zu bytes, %zu readable: padding with zeros", w, h, size, ok);
    void *copy = calloc(1, size);
    if (!copy) return NULL;
    memcpy(copy, p, ok);
    *d = copy;
    return copy;
}
// macOS games upload BGRA (CoronaCards: GL_BGRA with GL_UNSIGNED_INT_8_8_8_8, Apple's fast path). ES 3.0 has neither GL_BGRA as
// an upload format nor the packed 8_8_8_8 types, so those uploads (and RGBA in the non-REV packed type) are repacked as tight
// RGBA (or RGB) bytes; the caller frees the result. Unpack row length, skips and unpack buffers are not handled: passed on as is.
static void *repackPixels(GLsizei w, GLsizei h, GLenum *fmt, GLenum *type, const void **d) {
    if (!*d || w <= 0 || h <= 0) return NULL;
    BOOL bgra = *fmt == 0x80E1, bgr = *fmt == 0x80E0, rgba = *fmt == GL_RGBA;
    if (rgba && *type == 0x8367) { *type = GL_UNSIGNED_BYTE; return NULL; }   // 8_8_8_8_REV: memory is R,G,B,A already
    BOOL packed = *type == 0x8035, ok = ((bgra || rgba) && packed) || (bgra && (*type == 0x8367 || *type == GL_UNSIGNED_BYTE)) || (bgr && *type == GL_UNSIGNED_BYTE);
    if (!ok) return NULL;
    GLint align = 4, row = 0, skipP = 0, skipR = 0, pbo = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (row || skipP || skipR || pbo || align < 1) return NULL;
    size_t bpp = bgr ? 3 : 4, stride = ((size_t)w * bpp + (size_t)align - 1) / (size_t)align * (size_t)align;
    uint8_t *out = malloc((size_t)w * (size_t)h * bpp);
    if (!out) return NULL;
    for (GLsizei y = 0; y < h; y++) {
        const uint8_t *src = (const uint8_t *)*d + (size_t)y * stride;
        uint8_t *dst = out + (size_t)y * (size_t)w * bpp;
        for (GLsizei x = 0; x < w; x++, src += bpp, dst += bpp) {
            if (bgr || (bgra && !packed)) { dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; if (!bgr) dst[3] = src[3]; continue; }
            uint32_t v; memcpy(&v, src, 4);
            if (bgra) { dst[0] = (uint8_t)(v >> 8); dst[1] = (uint8_t)(v >> 16); dst[2] = (uint8_t)(v >> 24); dst[3] = (uint8_t)v; }
            else { dst[0] = (uint8_t)(v >> 24); dst[1] = (uint8_t)(v >> 16); dst[2] = (uint8_t)(v >> 8); dst[3] = (uint8_t)v; }
        }
    }
    *fmt = bgr ? GL_RGB : GL_RGBA; *type = GL_UNSIGNED_BYTE; *d = out;
    return out;
}
// Runs `send` with a 1-byte unpack alignment when the repacked rows are not 4-byte multiples (RGB).
static void withTightRows(BOOL tight, void (^send)(void)) {
    GLint align = 4; if (tight) { glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glPixelStorei(GL_UNPACK_ALIGNMENT, 1); }
    send();
    if (tight) glPixelStorei(GL_UNPACK_ALIGNMENT, align);
}
static void shack_glTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum fmt, GLenum type, const void *d) {
    void *pad = guardedSource(w, h, fmt, type, &d);
    void *conv = repackPixels(w, h, &fmt, &type, &d);
    withTightRows(conv && fmt == GL_RGB, ^{ glTexSubImage2D(t, l, x, y, w, h, fmt, type, d); });
    free(conv); free(pad);
}
static void shack_glTexImage2D(GLenum t, GLint l, GLint f, GLsizei w, GLsizei h, GLint b, GLenum fmt, GLenum type, const void *d) {
    texLog("TexImage2D", t, l, f, w, h, fmt, type, d);
    void *pad = guardedSource(w, h, fmt, type, &d);
    void *conv = repackPixels(w, h, &fmt, &type, &d);
    f = renderable(f); if (!l) noteTex(t, (GLenum)f);
    withTightRows(conv && fmt == GL_RGB, ^{ glTexImage2D(t, l, f, w, h, b, fmt, type, d); });
    free(conv); free(pad);
}
static void shack_glTexImage3D(GLenum t, GLint l, GLint f, GLsizei w, GLsizei h, GLsizei dp, GLint b, GLenum fmt, GLenum type, const void *d) {
    if (!l) noteTex(t, (GLenum)f); glTexImage3D(t, l, f, w, h, dp, b, fmt, type, d);
}
static void shack_glTexStorage2D(GLenum t, GLsizei l, GLenum f, GLsizei w, GLsizei h) {
    f = ShackBCStorageFormat((GLenum)renderable((GLint)f)); noteTex(t, f); glTexStorage2D(t, l, f, w, h);
}
static void shack_glTexStorage3D(GLenum t, GLsizei l, GLenum f, GLsizei w, GLsizei h, GLsizei dp) {
    f = ShackBCStorageFormat(f); noteTex(t, f); glTexStorage3D(t, l, f, w, h, dp);
}
// S3TC/RGTC uploads, decoded on the CPU (ShackGLTexture.m); other compressed formats pass through.
static void shack_glCompressedTexImage2D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLint b, GLsizei n, const void *d) {
    if (!ShackBCCompressedTexImage2D(t, l, f, w, h, n, d)) glCompressedTexImage2D(t, l, f, w, h, b, n, d);
    else if (!l) noteTex(t, ShackBCStorageFormat(f));
}
static void shack_glCompressedTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLsizei n, const void *d) {
    if (!ShackBCCompressedTexSubImage2D(t, l, x, y, w, h, f, n, d)) glCompressedTexSubImage2D(t, l, x, y, w, h, f, n, d);
}
static void shack_glCompressedTexImage3D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLsizei dp, GLint b, GLsizei n, const void *d) {
    if (!ShackBCCompressedTexImage3D(t, l, f, w, h, dp, n, d)) glCompressedTexImage3D(t, l, f, w, h, dp, b, n, d);
}
static void shack_glCompressedTexSubImage3D(GLenum t, GLint l, GLint x, GLint y, GLint z, GLsizei w, GLsizei h, GLsizei dp, GLenum f, GLsizei n, const void *d) {
    if (!ShackBCCompressedTexSubImage3D(t, l, x, y, z, w, h, dp, f, n, d)) glCompressedTexSubImage3D(t, l, x, y, z, w, h, dp, f, n, d);
}
static void shack_glRenderbufferStorage(GLenum t, GLenum f, GLsizei w, GLsizei h) {
    f = (GLenum)renderable((GLint)f);
    GLint r = 0; glGetIntegerv(GL_RENDERBUFFER_BINDING, &r); if (r > 0 && r < 8192) gRBFormat[r] = f;
    glRenderbufferStorage(t, f, w, h);
}
// Desktop readback of buffer contents (Godot 3's mesh_surface_get_array, e.g. building AnimatedSprite3D); ES 3.0 maps.
static void shack_glGetBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void *data) {
    void *p = size > 0 ? glMapBufferRange(target, offset, size, GL_MAP_READ_BIT) : NULL;
    if (!p) return;
    memcpy(data, p, (size_t)size);
    glUnmapBuffer(target);
}
// Base-vertex draws (GL 3.2; ES only from 3.2, iOS has 3.0; FNA3D draws every mesh with them): each enabled
// buffer-backed attribute is re-pointed baseVertex vertices on, read back from GL rather than tracked so any VAO
// works, then restored. Client-memory attributes are left alone. ponytail: glGets per draw, only when baseVertex != 0.
static GLint AttribBytes(GLint size, GLenum type) {
    switch (type) {
    case GL_BYTE: case GL_UNSIGNED_BYTE: return size;
    case GL_SHORT: case GL_UNSIGNED_SHORT: case GL_HALF_FLOAT: return 2 * size;
    case GL_INT_2_10_10_10_REV: case GL_UNSIGNED_INT_2_10_10_10_REV: return 4;
    default: return 4 * size;   // GL_INT, GL_UNSIGNED_INT, GL_FLOAT, GL_FIXED
    }
}
static void BaseVertexDraw(GLint baseVertex, void (^draw)(void)) {
    if (!baseVertex) { draw(); return; }
    enum { N = 16 };
    struct { GLint on, buf, size, type, norm, stride, integer; void *ptr; } a[N];
    GLint max = 0, bound = 0;
    glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &max); if (max > N) max = N;
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &bound);
    for (GLint i = 0; i < max; i++) {
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a[i].on);
        if (a[i].on) glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &a[i].buf);
        if (!a[i].on || !a[i].buf) { a[i].on = 0; continue; }
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a[i].size);
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a[i].type);
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a[i].norm);
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a[i].stride);
        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_INTEGER, &a[i].integer);
        glGetVertexAttribPointerv(i, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a[i].ptr);
    }
    for (int pass = 0; pass < 2; pass++) {   // 0: shift, 1: restore
        for (GLint i = 0; i < max; i++) {
            if (!a[i].on) continue;
            GLint step = a[i].stride ? a[i].stride : AttribBytes(a[i].size, a[i].type);
            const char *p = (const char *)a[i].ptr + (pass ? 0 : (intptr_t)baseVertex * step);
            glBindBuffer(GL_ARRAY_BUFFER, (GLuint)a[i].buf);
            if (a[i].integer) glVertexAttribIPointer(i, a[i].size, a[i].type, a[i].stride, p);
            else glVertexAttribPointer(i, a[i].size, a[i].type, (GLboolean)a[i].norm, a[i].stride, p);
        }
        glBindBuffer(GL_ARRAY_BUFFER, (GLuint)bound);
        if (!pass) draw();
    }
}
static void shack_glDrawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *indices, GLint baseVertex) {
    BaseVertexDraw(baseVertex, ^{ glDrawElements(mode, count, type, indices); });
}
static void shack_glDrawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices, GLint baseVertex) {
    BaseVertexDraw(baseVertex, ^{ glDrawRangeElements(mode, start, end, count, type, indices); });
}
static void shack_glDrawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instances, GLint baseVertex) {
    BaseVertexDraw(baseVertex, ^{ glDrawElementsInstanced(mode, count, type, indices, instances); });
}
static GLenum shack_glCheckFramebufferStatus(GLenum target) {
    GLenum st = glCheckFramebufferStatus(target);
    static atomic_int logged;
    if (st != GL_FRAMEBUFFER_COMPLETE && atomic_fetch_add(&logged, 1) < 12) {
        NSMutableString *m = [NSMutableString stringWithFormat:@"[ShackGL] framebuffer incomplete 0x%x:", st];
        const GLenum att[] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2, GL_COLOR_ATTACHMENT3, GL_DEPTH_ATTACHMENT, GL_STENCIL_ATTACHMENT };
        for (int i = 0; i < 6; i++) {
            GLint type = 0, name = 0;
            glGetFramebufferAttachmentParameteriv(target, att[i], GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
            if (type == GL_NONE) continue;
            glGetFramebufferAttachmentParameteriv(target, att[i], GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
            GLenum f = name > 0 && name < 8192 ? (type == GL_TEXTURE ? gTexFormat[name] : gRBFormat[name]) : 0;
            [m appendFormat:@" %@%d=%@ %d fmt 0x%x", i < 4 ? @"color" : @"", i < 4 ? i : 0, type == GL_TEXTURE ? @"tex" : @"rb", name, f];
        }
        NSLog(@"%@", m);
    }
    return st;
}

// Desktop entry points ES does not have resolve to a stub that returns 0 and logs its name when first called, not
// NULL: glad loads every desktop 3.3 name, and a game calling one jumped to address 0 (Cosmic Call entering a level).
// ponytail: 1024 compiled-in slots (no runtime code generation on iOS; glad asks for ~300 desktop-only names); names
// past that stay NULL and are logged.
#define SHACK_GL_SLOTS 1024
static const char *gMissing[SHACK_GL_SLOTS];
static atomic_bool gMissingSaid[SHACK_GL_SLOTS];
static long missingCalled(int i) {
    if (!atomic_exchange(&gMissingSaid[i], true)) NSLog(@"[ShackGL] %s called: no OpenGL ES equivalent, ignored", gMissing[i]);
    return 0;
}
// Slot names are five base-4 digits (S256(2) -> 20000..23333); 0##n reads them as octal, slot() makes that 0..1023.
static int slot(int v) { return ((v >> 12) & 7) * 256 + ((v >> 9) & 7) * 64 + ((v >> 6) & 7) * 16 + ((v >> 3) & 7) * 4 + (v & 7); }
#define S1(n) static long shack_glMissing##n(void) { return missingCalled(slot(0##n)); }
#define S4(n) S1(n##0) S1(n##1) S1(n##2) S1(n##3)
#define S16(n) S4(n##0) S4(n##1) S4(n##2) S4(n##3)
#define S64(n) S16(n##0) S16(n##1) S16(n##2) S16(n##3)
#define S256(n) S64(n##0) S64(n##1) S64(n##2) S64(n##3)
S256(0) S256(1) S256(2) S256(3)
#define P1(n) (void *)shack_glMissing##n,
#define P4(n) P1(n##0) P1(n##1) P1(n##2) P1(n##3)
#define P16(n) P4(n##0) P4(n##1) P4(n##2) P4(n##3)
#define P64(n) P16(n##0) P16(n##1) P16(n##2) P16(n##3)
#define P256(n) P64(n##0) P64(n##1) P64(n##2) P64(n##3)
static void *const gMissingStub[SHACK_GL_SLOTS] = { P256(0) P256(1) P256(2) P256(3) };

void *ShackGLGetProcAddress(const char *name) {
    static const struct { const char *name; void *fn; } own[] = {
        {"glGetString", shack_glGetString}, {"glShaderSource", shack_glShaderSource}, {"glClearDepth", shack_glClearDepth},
        {"glDepthRange", shack_glDepthRange}, {"glBindFramebuffer", shack_glBindFramebuffer},
        {"glTexParameteriv", shack_glTexParameteriv}, {"glTexImage2D", shack_glTexImage2D}, {"glTexSubImage2D", shack_glTexSubImage2D}, {"glTexImage3D", shack_glTexImage3D},
        {"glTexStorage2D", shack_glTexStorage2D}, {"glTexStorage3D", shack_glTexStorage3D}, {"glRenderbufferStorage", shack_glRenderbufferStorage},
        {"glCompressedTexImage2D", shack_glCompressedTexImage2D}, {"glCompressedTexSubImage2D", shack_glCompressedTexSubImage2D},
        {"glCompressedTexImage3D", shack_glCompressedTexImage3D}, {"glCompressedTexSubImage3D", shack_glCompressedTexSubImage3D},
        {"glCheckFramebufferStatus", shack_glCheckFramebufferStatus}, {"glGetBufferSubData", shack_glGetBufferSubData},
        {"glDrawElementsBaseVertex", shack_glDrawElementsBaseVertex}, {"glDrawRangeElementsBaseVertex", shack_glDrawRangeElementsBaseVertex},
        {"glDrawElementsInstancedBaseVertex", shack_glDrawElementsInstancedBaseVertex},
    };
    for (size_t i = 0; i < sizeof own / sizeof *own; i++) if (!strcmp(name, own[i].name)) return own[i].fn;
    void *legacy = ShackGLLegacyProc(name);
    if (legacy) return legacy;
    static void *gles; static dispatch_once_t once;
    dispatch_once(&once, ^{ gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY); });
    void *f = dlsym(gles, name);
    if (f || strncmp(name, "gl", 2)) return f;
    // glGenFramebuffersEXT, glBlendEquationEXT, glUniform1fARB...: the core name ES has (through this table again).
    size_t n = strlen(name);
    // glBindVertexArrayAPPLE and its two siblings (CoronaCards) are ES 3.0's core VAO calls.
    size_t suffix = n > 8 && !strcmp(name + n - 5, "APPLE") ? 5 : n > 5 && (!strcmp(name + n - 3, "EXT") || !strcmp(name + n - 3, "ARB")) ? 3 : 0;
    if (suffix) {
        char base[128];
        if (n - suffix < sizeof base) { memcpy(base, name, n - suffix); base[n - suffix] = 0; if ((f = ShackGLGetProcAddress(base))) return f; }
    }
    static atomic_int used;
    int i = atomic_fetch_add(&used, 1);
    if (i >= SHACK_GL_SLOTS) { NSLog(@"[ShackGL] out of stub slots: %s stays NULL", name); return NULL; }
    gMissing[i] = strdup(name);
    return gMissingStub[i];
}
