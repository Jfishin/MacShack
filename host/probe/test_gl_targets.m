// Render targets as desktop GL allocates them, on OpenGL ES 3: empty textures in BGRA/8_8_8_8_REV (Batman's sRGB scene
// color: ES refused the format with a sized internal format, the texture stayed empty and every draw into its
// framebuffer failed with GL_INVALID_FRAMEBUFFER_OPERATION) and 16-bit normalized formats ES does not have (GL_RGBA16,
// GL_RG16: made 16-bit float). Through ShackGLTexAlloc, in the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_targets.m -framework Foundation -framework OpenGLES -o /tmp/tt && xcrun simctl spawn booted /tmp/tt
// expect `gl targets ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

void ShackGLTexAlloc(GLint *internal, GLenum *fmt, GLenum *type, const void *data);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        const struct { GLint internal; GLenum fmt, type; const char *what; } cases[] = {
            { GL_SRGB8_ALPHA8, 0x80E1, 0x8367, "SRGB8_ALPHA8 from BGRA 8_8_8_8_REV" },
            { GL_RGBA8, 0x80E1, GL_UNSIGNED_BYTE, "RGBA8 from BGRA bytes" },
            { 0x805B, GL_RGBA, GL_UNSIGNED_SHORT, "RGBA16" },
            { 0x822C, GL_RG, GL_UNSIGNED_SHORT, "RG16" },
            { GL_RGBA16F, GL_RGBA, GL_FLOAT, "RGBA16F from floats" },
        };
        for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
            GLint f = cases[i].internal; GLenum fmt = cases[i].fmt, type = cases[i].type;
            ShackGLTexAlloc(&f, &fmt, &type, NULL);
            GLuint t, fb; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
            glTexImage2D(GL_TEXTURE_2D, 0, f, 8, 8, 0, fmt, type, NULL);
            GLenum err = glGetError();
            glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
            GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (err != GL_NO_ERROR || st != GL_FRAMEBUFFER_COMPLETE) {
                fprintf(stderr, "FAIL: %s -> %#x %#x %#x: error %#x status %#x\n", cases[i].what, f, fmt, type, err, st); return 1;
            }
        }
        // with pixels a BGRA upload is the shim's repack's business, not this: untouched
        GLint f = GL_RGBA8; GLenum fmt = 0x80E1, type = GL_UNSIGNED_BYTE; unsigned char px[4] = {0};
        ShackGLTexAlloc(&f, &fmt, &type, px);
        if (fmt != 0x80E1) { fprintf(stderr, "FAIL: a data upload's format changed\n"); return 1; }
        puts("gl targets ok");
    }
}
