// Occlusion queries as desktop GL has them (GL_ARB_occlusion_query: GL_SAMPLES_PASSED, counter bits, glGetQueryObjectiv)
// on OpenGL ES 3, which counts only "any samples passed". Batman's IndirectX gives its D3D9 occlusion queries no GL query
// without the extension and then issues them through NULL (its crash on the way to the main menu, 2026-10-14). Through
// ShackGLLegacyProc and ShackGLLegacyExtensions, in the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_queries.m -framework Foundation -framework OpenGLES -o /tmp/tq && xcrun simctl spawn booted /tmp/tq
// expect `gl queries ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

void *ShackGLLegacyProc(const char *name);
const GLubyte *ShackGLLegacyExtensions(void);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here
enum { SAMPLES_PASSED = 0x8914, QUERY_COUNTER_BITS = 0x8864 };

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        NSString *ext = @((const char *)ShackGLLegacyExtensions());
        void (*getiv)(GLenum, GLenum, GLint *) = ShackGLLegacyProc("glGetQueryiv");
        void (*begin)(GLenum, GLuint) = ShackGLLegacyProc("glBeginQuery");
        void (*end)(GLenum) = ShackGLLegacyProc("glEndQuery");
        void (*objectiv)(GLuint, GLenum, GLint *) = ShackGLLegacyProc("glGetQueryObjectiv");
        if (![ext containsString:@"GL_ARB_occlusion_query "] || ![ext containsString:@"GL_ARB_occlusion_query2"] ||
            !getiv || !begin || !end || !objectiv) {
            fprintf(stderr, "FAIL: extension %d/%d, functions %p %p %p %p\n", [ext containsString:@"GL_ARB_occlusion_query "],
                    [ext containsString:@"GL_ARB_occlusion_query2"], getiv, begin, end, objectiv); return 1;
        }
        GLint bits = 0; getiv(SAMPLES_PASSED, QUERY_COUNTER_BITS, &bits);
        GLuint fb, rb, q;   // a 4x4 target, a cleared draw counts no samples: the query works and answers
        glGenFramebuffers(1, &fb); glGenRenderbuffers(1, &rb);
        glBindRenderbuffer(GL_RENDERBUFFER, rb); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 4, 4);
        glBindFramebuffer(GL_FRAMEBUFFER, fb); glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
        glGenQueries(1, &q);
        begin(SAMPLES_PASSED, q);
        GLint current = 0; getiv(SAMPLES_PASSED, GL_CURRENT_QUERY, &current);
        end(SAMPLES_PASSED);
        glFinish();
        GLint avail = 0, result = -1;
        objectiv(q, GL_QUERY_RESULT_AVAILABLE, &avail);
        objectiv(q, GL_QUERY_RESULT, &result);
        GLenum err = glGetError();
        if (bits <= 0 || current != (GLint)q || !avail || result != 0 || err != GL_NO_ERROR) {
            fprintf(stderr, "FAIL: bits %d current %d available %d result %d error %#x\n", bits, current, avail, result, err); return 1;
        }
        puts("gl queries ok");
    }
}
