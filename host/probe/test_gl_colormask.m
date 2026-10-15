// glColorMaski (GL 3.0, per draw buffer) on OpenGL ES 3.0, which has only glColorMask: buffer 0's mask is the context's.
// Scaleform (Batman's menus) draws its clip masks with color writes off; ignored, they showed as solid boxes. Through
// ShackGLLegacyProc, in the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_colormask.m -framework Foundation -framework OpenGLES -o /tmp/tm && xcrun simctl spawn booted /tmp/tm
// expect `gl colormask ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

void *ShackGLLegacyProc(const char *name);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        void (*maski)(GLuint, GLboolean, GLboolean, GLboolean, GLboolean) = ShackGLLegacyProc("glColorMaski");
        if (!maski) { fprintf(stderr, "FAIL: no glColorMaski\n"); return 1; }
        GLboolean m[4] = {1, 1, 1, 1};
        maski(0, GL_FALSE, GL_TRUE, GL_FALSE, GL_FALSE);
        glGetBooleanv(GL_COLOR_WRITEMASK, m);
        BOOL zeroOK = !m[0] && m[1] && !m[2] && !m[3];
        maski(1, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);   // another buffer's: not the context's
        glGetBooleanv(GL_COLOR_WRITEMASK, m);
        if (!zeroOK || m[0] || !m[1] || glGetError() != GL_NO_ERROR) { fprintf(stderr, "FAIL: write mask %d%d%d%d\n", m[0], m[1], m[2], m[3]); return 1; }
        puts("gl colormask ok");
    }
}
