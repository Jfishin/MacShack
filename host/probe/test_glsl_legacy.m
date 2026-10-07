// GLSL 1.x shaders through ShackGLLegacySource (shims/AppKit/ShackGLLegacy.m), compiled by the iOS Simulator's OpenGL ES 3.
// A directory of sources (OCERZ_M32_SHADERDUMP=<dir> on the Mac writes Batman's) is the corpus; a shader is a vertex
// shader when it writes gl_Position.
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_glsl_legacy.m -framework Foundation -framework OpenGLES -o /tmp/tglsl
//   xcrun simctl spawn booted /tmp/tglsl <shader dir>
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

NSString *ShackGLLegacySource(NSString *src, GLenum type);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {}   // ShackGL.m's; unused here

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: %s <shader dir>\n", argv[0]); return 2; }
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        NSString *dir = @(argv[1]);
        int ok = 0, bad = 0;
        for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name hasSuffix:@".glsl"]) continue;
            NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
            if (!src) continue;
            GLenum type = [src containsString:@"gl_Position"] ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER;
            NSString *es = ShackGLLegacySource(src, type);
            if (!es) { printf("SKIP %s (not GLSL 1.x)\n", name.UTF8String); continue; }
            const char *s = es.UTF8String;
            GLuint sh = glCreateShader(type);
            glShaderSource(sh, 1, &s, NULL);
            glCompileShader(sh);
            GLint good = 0;
            glGetShaderiv(sh, GL_COMPILE_STATUS, &good);
            if (good) ok++;
            else {
                char log[2048] = "";
                glGetShaderInfoLog(sh, sizeof log, NULL, log);
                printf("FAIL %s (%s): %s\n", name.UTF8String, type == GL_VERTEX_SHADER ? "vertex" : "fragment", log);
                bad++;
            }
            glDeleteShader(sh);
        }
        printf("%d compiled, %d failed\n", ok, bad);
        return bad ? 1 : 0;
    }
}
