// BGRA uploads on OpenGL ES 3 (which has no GL_BGRA upload format): the shim repacks them as RGBA (ShackGLRepack) and
// sends them with tight unpack state (ShackGLUnpackTight). Batman uploads its sRGB 2D and cube textures with
// GL_UNPACK_ROW_LENGTH set, which the repack used to pass over: ES refused the BGRA data and the textures stayed empty.
// In the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_repack.m -framework Foundation -framework OpenGLES -o /tmp/tr && xcrun simctl spawn booted /tmp/tr
// expect `gl repack ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

void *ShackGLRepack(GLsizei w, GLsizei h, GLenum *fmt, GLenum *type, const void **d);
void ShackGLUnpackTight(BOOL repacked, GLenum fmt, void (^send)(void));
void ShackGLTexAlloc(GLint *internal, GLenum *fmt, GLenum *type, const void *data);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        // a 4x3 BGRA image; the 2x2 upload starts at pixel 1 of row 1 (row length 4)
        uint8_t img[3][4][4];
        for (int y = 0; y < 3; y++) for (int x = 0; x < 4; x++) {
            img[y][x][0] = (uint8_t)(10 * x + y); img[y][x][1] = 100; img[y][x][2] = (uint8_t)(200 + y); img[y][x][3] = 255;   // B G R A
        }
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, 4);
        glPixelStorei(GL_UNPACK_SKIP_PIXELS, 1); glPixelStorei(GL_UNPACK_SKIP_ROWS, 1);
        GLenum fmt = 0x80E1, type = 0x8367; const void *d = img;
        void *conv = ShackGLRepack(2, 2, &fmt, &type, &d);
        GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
        ShackGLUnpackTight(conv != NULL, fmt, ^{ glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, fmt, type, d); });
        free(conv);
        GLenum err = glGetError();
        GLint row = -1, skipP = -1, skipR = -1, align = -1;
        glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row); glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP);
        glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR); glGetIntegerv(GL_UNPACK_ALIGNMENT, &align);
        if (!conv || err != GL_NO_ERROR || row != 4 || skipP != 1 || skipR != 1 || align != 1) {
            fprintf(stderr, "FAIL: repacked %d error %#x, unpack state after %d %d %d %d\n", conv != NULL, err, row, skipP, skipR, align); return 1;
        }
        GLuint fb; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
        uint8_t px[4] = {0};
        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);   // texel (1,1) = image pixel (2,2)
        if (px[0] != 202 || px[1] != 100 || px[2] != 22 || px[3] != 255) {
            fprintf(stderr, "FAIL: texel %d %d %d %d (want 202 100 22 255)\n", px[0], px[1], px[2], px[3]); return 1;
        }
        // GL 1.0's component count as the internal format (Titan Souls: 4, BGRA bytes): an RGBA texture, not an error.
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0); glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0); glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
        GLint internal = 4; fmt = 0x80E1; type = GL_UNSIGNED_BYTE; d = img;
        conv = ShackGLRepack(4, 3, &fmt, &type, &d);
        ShackGLTexAlloc(&internal, &fmt, &type, d);
        GLuint t4; glGenTextures(1, &t4); glBindTexture(GL_TEXTURE_2D, t4);
        ShackGLUnpackTight(conv != NULL, fmt, ^{ glTexImage2D(GL_TEXTURE_2D, 0, internal, 4, 3, 0, fmt, type, d); });
        free(conv);
        err = glGetError();
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t4, 0);
        memset(px, 0, sizeof px);
        glReadPixels(3, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);   // image pixel (3,2): B 32, G 100, R 202
        if (internal != GL_RGBA || err != GL_NO_ERROR || px[0] != 202 || px[1] != 100 || px[2] != 32 || px[3] != 255) {
            fprintf(stderr, "FAIL: component count 4 -> %#x, error %#x, texel %d %d %d %d (want 202 100 32 255)\n",
                    internal, err, px[0], px[1], px[2], px[3]); return 1;
        }
        puts("gl repack ok");
    }
}
