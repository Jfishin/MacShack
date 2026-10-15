// CGL's surface backing size (Feral's windowed resolution: Batman asks for 960x720 whatever the view is): the default
// framebuffer is an offscreen one of that size, stretched onto the layer's at each present (shims/AppKit/ShackGL.m uses
// ShackGLSurfaceFit/ShackGLSurfaceBlit). In the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_surface.m -framework Foundation -framework OpenGLES -o /tmp/tsurf && xcrun simctl spawn booted /tmp/tsurf
// expect `gl surface ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

GLuint ShackGLSurfaceFit(GLuint names[3], GLint size[2], GLint w, GLint h);
void ShackGLSurfaceBlit(const GLuint names[3], const GLint size[2], GLuint dst, GLint dw, GLint dh);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        GLuint layer, rb;   // the layer's framebuffer, 8x4
        glGenFramebuffers(1, &layer); glGenRenderbuffers(1, &rb);
        glBindRenderbuffer(GL_RENDERBUFFER, rb); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 8, 4);
        glBindFramebuffer(GL_FRAMEBUFFER, layer); glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        glClearColor(0, 0, 1, 1); glClear(GL_COLOR_BUFFER_BIT);
        GLuint names[3] = {0}; GLint size[2] = {0};
        GLuint fbo = ShackGLSurfaceFit(names, size, 4, 2);
        GLint bound = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &bound);
        if (!fbo || fbo == layer || bound != (GLint)layer || size[0] != 4 || size[1] != 2) {
            fprintf(stderr, "FAIL: fit -> %u (%dx%d), binding %d\n", fbo, size[0], size[1], bound); return 1;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { fprintf(stderr, "FAIL: surface incomplete\n"); return 1; }
        glClearColor(1, 0, 0, 1); glEnable(GL_SCISSOR_TEST); glScissor(0, 0, 4, 2); glClear(GL_COLOR_BUFFER_BIT);
        glScissor(0, 0, 1, 1);   // the game's scissor must not clip the present
        ShackGLSurfaceBlit(names, size, layer, 8, 4);
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &bound);
        GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
        glBindFramebuffer(GL_FRAMEBUFFER, layer);
        unsigned char px[4] = {0};
        glReadPixels(7, 3, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);   // the far corner: the 4x2 picture fills 8x4
        if (bound != (GLint)fbo || !scissor || px[0] != 255 || px[2] != 0 || glGetError() != GL_NO_ERROR) {
            fprintf(stderr, "FAIL: blit -> binding %d scissor %d pixel %d %d %d\n", bound, scissor, px[0], px[1], px[2]); return 1;
        }
        if (ShackGLSurfaceFit(names, size, 2, 2) != fbo || size[0] != 2) { fprintf(stderr, "FAIL: resize\n"); return 1; }
        puts("gl surface ok");
    }
}
