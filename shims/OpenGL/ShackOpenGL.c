// OpenGL.framework / AGL for macOS guests. No re-export: iOS has no OpenGL. The gl* sync calls are no-ops.
#include <stdint.h>
#include <stddef.h>

typedef int CGLError;
typedef void *CGLContextObj, *CGLPixelFormatObj, *CGLRendererInfoObj, *GLsync;
typedef int GLint, GLsizei; typedef unsigned GLuint, GLenum, GLbitfield; typedef uint64_t GLuint64;
enum { kCGLNoError = 0, kCGLBadPixelFormat = 10002, kCGLBadRendererInfo = 10003, kCGLBadContext = 10004 };
#define GL_ALREADY_SIGNALED 0x911A

// CGL runs on the AppKit shim's NSOpenGLContext (ShackGL.m, ShackCGL*) when desktop GL is on (SHACK_OPENGL=1: Unity
// games whose builds ship only GL shaders); otherwise every CGL call fails as before, and a GL path gives up at
// context creation.
#include <dlfcn.h>
static void *cgl(const char *name) {
    static int (*on)(void);
    if (!on) on = (int (*)(void))dlsym(RTLD_DEFAULT, "ShackCGLEnabled");
    return on && on() ? dlsym(RTLD_DEFAULT, name) : NULL;
}
#define CGL_FN(type, name) type (*f)() = (type (*)())cgl("Shack" #name)

CGLError CGLChoosePixelFormat(const int *attribs, CGLPixelFormatObj *pix, GLint *npix) {
    CGL_FN(CGLError, CGLChoosePixelFormat);
    if (f) return f(attribs, pix, npix);
    if (pix) *pix = NULL;
    if (npix) *npix = 0;
    return kCGLBadPixelFormat;
}
CGLError CGLCreateContext(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *ctx) {
    CGL_FN(CGLError, CGLCreateContext);
    if (f) return f(pix, share, ctx);
    if (ctx) *ctx = NULL;
    return kCGLBadContext;
}
CGLError CGLQueryRendererInfo(GLuint displayMask, CGLRendererInfoObj *rend, GLint *nrend) {
    int on = cgl("ShackCGLDescribeRenderer") != NULL;
    if (rend) *rend = on ? (CGLRendererInfoObj)1 : NULL;   // one renderer; the handle is only ever passed back
    if (nrend) *nrend = on;
    return on ? kCGLNoError : kCGLBadRendererInfo;
}
CGLError CGLDescribeRenderer(CGLRendererInfoObj rend, GLint n, int prop, GLint *value) {
    CGL_FN(CGLError, CGLDescribeRenderer);
    if (f && rend && n == 0) return f(prop, value);
    if (value) *value = 0;
    return kCGLBadRendererInfo;
}
CGLError CGLDestroyRendererInfo(CGLRendererInfoObj rend) { return kCGLNoError; }
CGLError CGLDestroyPixelFormat(CGLPixelFormatObj pix) {
    void (*f)(void *) = (void (*)(void *))cgl("ShackCGLRelease");
    if (f) f(pix);
    return kCGLNoError;
}
CGLError CGLDestroyContext(CGLContextObj ctx) {
    void (*f)(void *) = (void (*)(void *))cgl("ShackCGLRelease");
    if (f) f(ctx);
    return kCGLNoError;
}
void CGLReleaseContext(CGLContextObj ctx) { CGLDestroyContext(ctx); }
CGLContextObj CGLGetCurrentContext(void) {
    CGL_FN(CGLContextObj, CGLGetCurrentContext);
    return f ? f() : NULL;
}
CGLError CGLSetCurrentContext(CGLContextObj ctx) {
    CGL_FN(CGLError, CGLSetCurrentContext);
    if (f) return f(ctx);
    return ctx ? kCGLBadContext : kCGLNoError;   // clearing is fine
}
CGLPixelFormatObj CGLGetPixelFormat(CGLContextObj ctx) {
    CGL_FN(CGLPixelFormatObj, CGLGetPixelFormat);
    return f ? f(ctx) : NULL;
}
CGLError CGLEnable(CGLContextObj ctx, int pname) { return ctx && cgl("ShackCGLCreateContext") ? kCGLNoError : kCGLBadContext; }
CGLError CGLSetParameter(CGLContextObj ctx, int pname, const GLint *params) {
    CGL_FN(CGLError, CGLSetParameter);
    return f ? f(ctx, pname, params) : kCGLBadContext;
}
CGLError CGLFlushDrawable(CGLContextObj ctx) {
    CGL_FN(CGLError, CGLFlushDrawable);
    return f ? f(ctx) : kCGLBadContext;
}
// Calls Feral's renderer makes around its context (weak imports on a Mac too). The context is ES: nothing to disable or
// clear, no share group to hand out, and its "multithreaded engine" toggle is ours to ignore. CGLLockContext is a real lock
// (one recursive mutex for every context): the game locks around GL work it shares between threads.
#include <pthread.h>
CGLError CGLDisable(CGLContextObj ctx, int pname) { return ctx && cgl("ShackCGLCreateContext") ? kCGLNoError : kCGLBadContext; }
CGLError CGLClearDrawable(CGLContextObj ctx) { return ctx && cgl("ShackCGLCreateContext") ? kCGLNoError : kCGLBadContext; }
void *CGLGetShareGroup(CGLContextObj ctx) { return NULL; }
static pthread_mutex_t gCGLLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
CGLError CGLLockContext(CGLContextObj ctx) { return ctx ? (pthread_mutex_lock(&gCGLLock), kCGLNoError) : kCGLBadContext; }
CGLError CGLUnlockContext(CGLContextObj ctx) { return ctx ? (pthread_mutex_unlock(&gCGLLock), kCGLNoError) : kCGLBadContext; }
CGLError CGLTexImageIOSurface2D(CGLContextObj ctx, GLenum target, GLenum format, GLsizei w, GLsizei h, GLenum glformat, GLenum type, void *ioSurface, GLuint plane) { return kCGLBadContext; }   // IOSurface-backed textures: not supported

const char *CGLErrorString(CGLError e) { return e ? (cgl("ShackCGLCreateContext") ? "MacShack: CGL error" : "MacShack: no OpenGL on iOS") : "no error"; }

GLsync glFenceSync(GLenum condition, GLbitfield flags) { return NULL; }
GLenum glClientWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout) { return GL_ALREADY_SIGNALED; }
void glDeleteSync(GLsync sync) {}
void glFlush(void) {}

// Every other gl* function of the macOS SDK's OpenGL.framework (ShackGLFunctions.h), for native arm64 games that link the
// framework and bind them at load time (CoronaCards). Each export is a trampoline through a private slot that the first
// call fills from ShackGLGetProcAddress (the AppKit shim's GL layer: ES entry points, desktop-to-ES translations, and a
// logging no-op for what ES lacks). Argument registers survive the first call (x0-x8, q0-q7); stack arguments are untouched
// because the frame is gone before the jump. x86 games resolve gl* through ShackHooks and never come here.
#include "ShackGLFunctions.h"
__attribute__((visibility("hidden"))) void *shack_gl_resolve(const char *name, void **slot);
static long shack_gl_absent(void) { return 0; }
void *shack_gl_resolve(const char *name, void **slot) {
    static void *(*lookup)(const char *);
    if (!lookup) lookup = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "ShackGLGetProcAddress");
    void *fn = lookup ? lookup(name) : NULL;
    if (!fn) fn = (void *)shack_gl_absent;
    *slot = fn;   // a racing thread stores the same value
    return fn;
}
__asm__(
    ".text\n.private_extern _shack_gl_slow\n.p2align 2\n_shack_gl_slow:\n"   // x16 = slot, x17 = name
    "stp x29, x30, [sp, #-16]!\nmov x29, sp\nsub sp, sp, #208\n"
    "stp x0, x1, [sp, #0]\nstp x2, x3, [sp, #16]\nstp x4, x5, [sp, #32]\nstp x6, x7, [sp, #48]\nstr x8, [sp, #64]\n"
    "stp q0, q1, [sp, #80]\nstp q2, q3, [sp, #112]\nstp q4, q5, [sp, #144]\nstp q6, q7, [sp, #176]\n"
    "mov x0, x17\nmov x1, x16\nbl _shack_gl_resolve\nmov x16, x0\n"
    "ldp x0, x1, [sp, #0]\nldp x2, x3, [sp, #16]\nldp x4, x5, [sp, #32]\nldp x6, x7, [sp, #48]\nldr x8, [sp, #64]\n"
    "ldp q0, q1, [sp, #80]\nldp q2, q3, [sp, #112]\nldp q4, q5, [sp, #144]\nldp q6, q7, [sp, #176]\n"
    "add sp, sp, #208\nldp x29, x30, [sp], #16\nbr x16\n");
#define SHACK_GL_STUB(name) __asm__( \
    ".section __DATA,__data\n.p2align 3\nLshackslot_" #name ": .quad 0\n" \
    ".section __TEXT,__cstring,cstring_literals\nLshackname_" #name ": .asciz \"" #name "\"\n" \
    ".text\n.globl _" #name "\n.p2align 2\n_" #name ":\n" \
    "adrp x16, Lshackslot_" #name "@PAGE\nldr x17, [x16, Lshackslot_" #name "@PAGEOFF]\ncbz x17, 1f\nbr x17\n" \
    "1: add x16, x16, Lshackslot_" #name "@PAGEOFF\nadrp x17, Lshackname_" #name "@PAGE\n" \
    "add x17, x17, Lshackname_" #name "@PAGEOFF\nb _shack_gl_slow\n");
SHACK_GL_FUNCTIONS(SHACK_GL_STUB)
