// Enum-valued texture parameters given as floats (glTexParameterf/fv): desktop GL converts them; iOS's ES driver did not
// apply Feral's swizzles (D3D9 L8/A8 as GL_RED textures with GL_TEXTURE_SWIZZLE_* = (float)GL_RED / (float)GL_ONE), so
// Batman's menu showed those textures as opaque red. Through ShackGLLegacyProc, in the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_texparams.m -framework Foundation -framework OpenGLES -o /tmp/tp && xcrun simctl spawn booted /tmp/tp
// expect `gl texparams ok`.
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
        void (*paramf)(GLenum, GLenum, GLfloat) = ShackGLLegacyProc("glTexParameterf");
        void (*paramfv)(GLenum, GLenum, const GLfloat *) = ShackGLLegacyProc("glTexParameterfv");
        if (!paramf || !paramfv) { fprintf(stderr, "FAIL: no glTexParameterf/glTexParameterfv\n"); return 1; }
        GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
        paramf(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, (GLfloat)GL_RED);
        paramf(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, (GLfloat)GL_ONE);
        GLfloat zero = GL_ZERO; paramfv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, &zero);
        paramf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (GLfloat)GL_LINEAR);
        paramf(GL_TEXTURE_2D, GL_TEXTURE_MAX_LOD, 3.5f);   // a real float stays one
        GLint g = 0, b = -1, a = 0, minf = 0; GLfloat maxlod = 0;
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_G, &g); glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, &b);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, &a); glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minf);
        glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LOD, &maxlod);
        if (g != GL_RED || b != GL_ZERO || a != GL_ONE || minf != GL_LINEAR || maxlod != 3.5f || glGetError() != GL_NO_ERROR) {
            fprintf(stderr, "FAIL: swizzle g %#x b %#x a %#x, min filter %#x, max lod %g\n", g, b, a, minf, maxlod); return 1;
        }
        puts("gl texparams ok");
    }
}
