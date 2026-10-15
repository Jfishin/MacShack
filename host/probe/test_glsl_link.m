// Desktop GL links several shaders of one stage; ES one. Feral's IndirectX (Batman) attaches a second fragment shader
// holding alphaTest(), which its main shader only declares. Through ShackGLLegacyProc's glAttachShader/glLinkProgram,
// in the iOS Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_glsl_link.m -framework Foundation -framework OpenGLES -o /tmp/tlink && xcrun simctl spawn booted /tmp/tlink
// expect `glsl link ok`.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

NSString *ShackGLESSource(NSString *src, GLenum type);
void *ShackGLLegacyProc(const char *name);
void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {
    GLint type = 0; glGetShaderiv(shader, GL_SHADER_TYPE, &type);   // ShackGL.m's, which converts the same way
    const GLchar *s = ShackGLESSource([[NSString alloc] initWithBytes:strings[0] length:strlen(strings[0]) encoding:NSUTF8StringEncoding], (GLenum)type).UTF8String;
    glShaderSource(shader, 1, &s, NULL);
}
static GLuint shader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    ShackGLShaderSource(sh, 1, &src, NULL);
    ((void (*)(GLuint))ShackGLLegacyProc("glCompileShader"))(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { fprintf(stderr, "FAIL: compile %s\n", src); exit(1); }
    return sh;
}

int main(void) {
    @autoreleasepool {
        EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!ctx || ![EAGLContext setCurrentContext:ctx]) { fprintf(stderr, "no ES 3 context\n"); return 2; }
        void (*attach)(GLuint, GLuint) = ShackGLLegacyProc("glAttachShader");
        void (*detach)(GLuint, GLuint) = ShackGLLegacyProc("glDetachShader");
        void (*link)(GLuint) = ShackGLLegacyProc("glLinkProgram");
        if (!attach || !detach || !link) { fprintf(stderr, "FAIL: no glAttachShader/glDetachShader/glLinkProgram\n"); return 1; }
        GLuint vs = shader(GL_VERTEX_SHADER, "#version 330\n\n// vs_3_0\nlayout(location = 0) in vec4 pos;\nvoid main() { gl_Position = pos; }\n");
        GLuint fs = shader(GL_FRAGMENT_SHADER, "#version 330\n\n// ps_3_0\nout vec4 color;\nvoid alphaTest(float inFragAlpha);\n"
                                               "void main() { color = vec4(0.5); alphaTest(color.a); }\n");
        GLuint at = shader(GL_FRAGMENT_SHADER, "#version 330\n\nuniform vec4 feral_alphaRef;\nvoid alphaTest(float inFragAlpha)\n"
                                               "{\n\tif (inFragAlpha < feral_alphaRef.x)\n\t\tdiscard;\n}\n");
        GLuint none = shader(GL_FRAGMENT_SHADER, "#version 330\n\nvoid alphaTest(float inFragAlpha)\n{\n}\n");
        GLuint prog = glCreateProgram();
        attach(prog, vs); attach(prog, fs); attach(prog, at);
        link(prog);
        GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok || glGetUniformLocation(prog, "feral_alphaRef") < 0) { fprintf(stderr, "FAIL: link with alphaTest %d\n", ok); return 1; }
        // the game swaps the alpha test and links again: the swapped-in one counts, the detached one no longer does
        detach(prog, at); attach(prog, none);
        link(prog);
        glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok || glGetUniformLocation(prog, "feral_alphaRef") >= 0) { fprintf(stderr, "FAIL: relink with the other alphaTest %d\n", ok); return 1; }
        GLsizei n = 0; GLuint sh[8]; glGetAttachedShaders(prog, 8, &n, sh);
        if (n != 2 || glGetError() != GL_NO_ERROR) { fprintf(stderr, "FAIL: %d attached after link\n", n); return 1; }
        // user clip planes: GLSL 1.30+ writes gl_ClipDistance, which ES 3.0 has only through GL_APPLE_clip_distance
        // (Feral's light vertex shaders, Batman)
        GLuint clip = shader(GL_VERTEX_SHADER, "#version 330\n\n// vs_3_0\nlayout(location = 0) in vec4 pos;\nuniform vec4 plane;\n"
                                               "void main() { gl_Position = pos; gl_ClipDistance[0] = dot(pos, plane); }\n");
        glDeleteShader(clip);
        puts("glsl link ok");
    }
}
