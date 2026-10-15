// Desktop core GL lets an enabled vertex attribute have no buffer and a NULL pointer (Feral's GL 3 path leaves the D3D
// streams a draw does not feed that way); iOS's GLEngine fetches such an attribute as a client array at address 0 and
// faults (Batman's freeze after the intro, 2026-10-14). Through ShackGLLegacyProc's glVertexAttribPointer, in the iOS
// Simulator's OpenGL ES 3:
//   xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios26.0-simulator shims/AppKit/ShackGLLegacy.m \
//     host/probe/test_gl_attribs.m -framework Foundation -framework OpenGLES -o /tmp/tattr && xcrun simctl spawn booted /tmp/tattr
// expect `gl attribs ok`.
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
        void (*pointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *) = ShackGLLegacyProc("glVertexAttribPointer");
        void (*ipointer)(GLuint, GLint, GLenum, GLsizei, const void *) = ShackGLLegacyProc("glVertexAttribIPointer");
        if (!pointer || !ipointer) { fprintf(stderr, "FAIL: no glVertexAttribPointer/glVertexAttribIPointer\n"); return 1; }
        GLuint vao, vb;
        glGenVertexArrays(1, &vao); glBindVertexArray(vao);
        glGenBuffers(1, &vb); glBindBuffer(GL_ARRAY_BUFFER, vb);
        GLfloat v[6] = {0};
        glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STATIC_DRAW);
        pointer(0, 2, GL_FLOAT, GL_FALSE, 8, (const void *)0);   // a real stream, offset 0 in vb: left as it is
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        pointer(3, 4, GL_FLOAT, GL_FALSE, 0, NULL);              // an unfed stream: no buffer, NULL
        ipointer(4, 4, GL_INT, 0, NULL);
        GLint b0 = 0, b3 = 0, b4 = 0, bound = -1;
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b0);
        glGetVertexAttribiv(3, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b3);
        glGetVertexAttribiv(4, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b4);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &bound);
        if (b0 != (GLint)vb || !b3 || b3 == (GLint)vb || b4 != b3 || bound != 0 || glGetError() != GL_NO_ERROR) {
            fprintf(stderr, "FAIL: attribute buffers %d %d %d, array buffer %d\n", b0, b3, b4, bound); return 1;
        }
        // the zero buffer holds zeros
        glBindBuffer(GL_COPY_READ_BUFFER, (GLuint)b3);
        const GLfloat *z = glMapBufferRange(GL_COPY_READ_BUFFER, 0, 16, GL_MAP_READ_BIT);
        BOOL zero = z && z[0] == 0 && z[1] == 0 && z[2] == 0 && z[3] == 0;
        glUnmapBuffer(GL_COPY_READ_BUFFER);
        if (!zero) { fprintf(stderr, "FAIL: zero buffer not zero\n"); return 1; }
        // a fed stream whose buffer is deleted while the VAO still uses it: ES leaves buffer 0 and the offset (GLEngine then
        // reads a client array at that address); it reads the zero buffer, and the stream on another buffer is untouched
        void (*del)(GLsizei, const GLuint *) = ShackGLLegacyProc("glDeleteBuffers");
        if (!del) { fprintf(stderr, "FAIL: no glDeleteBuffers\n"); return 1; }
        GLuint dyn; glGenBuffers(1, &dyn); glBindBuffer(GL_ARRAY_BUFFER, dyn);
        glBufferData(GL_ARRAY_BUFFER, 64, NULL, GL_DYNAMIC_DRAW);
        pointer(5, 4, GL_FLOAT, GL_FALSE, 0, (const void *)0);
        glEnableVertexAttribArray(5);
        glBindBuffer(GL_ARRAY_BUFFER, vb);
        del(1, &dyn);
        GLint b5 = 0, size5 = 0; bound = -1;
        glGetVertexAttribiv(5, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b5);
        glGetVertexAttribiv(5, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size5);
        glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b0);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &bound);
        if (b5 != b3 || size5 != 4 || b0 != (GLint)vb || bound != (GLint)vb || glIsBuffer(dyn) || glGetError() != GL_NO_ERROR) {
            fprintf(stderr, "FAIL: after delete: attribute 5 buffer %d size %d, attribute 0 %d, array buffer %d\n", b5, size5, b0, bound); return 1;
        }
        // enabled and never given a pointer (Batman's attributes 3-6: GL's defaults, buffer 0, NULL, 4 floats, stride 0):
        // the zero buffer too; a client array set after the enable stays one
        void (*enable)(GLuint) = ShackGLLegacyProc("glEnableVertexAttribArray");
        if (!enable) { fprintf(stderr, "FAIL: no glEnableVertexAttribArray\n"); return 1; }
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        enable(6);
        GLint b6 = 0, on6 = 0, size6 = 0;
        glGetVertexAttribiv(6, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b6);
        glGetVertexAttribiv(6, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &on6);
        glGetVertexAttribiv(6, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size6);
        static const GLfloat client[8];
        glBindVertexArray(0);   // ES 3 takes client arrays only outside a VAO (the legacy guests' case)
        enable(7);
        pointer(7, 2, GL_FLOAT, GL_FALSE, 0, client);
        GLint b7 = -1; void *p7 = NULL;
        glGetVertexAttribiv(7, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b7);
        glGetVertexAttribPointerv(7, GL_VERTEX_ATTRIB_ARRAY_POINTER, &p7);
        if (b6 != b3 || !on6 || size6 != 4 || b7 != 0 || p7 != client) {
            fprintf(stderr, "FAIL: enabled unfed attribute buffer %d on %d size %d; client array buffer %d pointer %p\n", b6, on6, size6, b7, p7); return 1;
        }
        // D3DCOLOR streams: desktop GL takes size GL_BGRA (ARB_vertex_array_bgra), ES refuses it (GL_INVALID_VALUE: Batman's
        // attributes 3-6 were never set); they arrive as 4 normalized bytes
        glBindVertexArray(vao); glBindBuffer(GL_ARRAY_BUFFER, vb);
        pointer(8, 0x80E1, GL_UNSIGNED_BYTE, GL_TRUE, 4, (const void *)4);
        GLint b8 = 0, size8 = 0; GLenum err8 = glGetError();
        glGetVertexAttribiv(8, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b8);
        glGetVertexAttribiv(8, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size8);
        if (err8 != GL_NO_ERROR || b8 != (GLint)vb || size8 != 4) {
            fprintf(stderr, "FAIL: BGRA attribute error %#x buffer %d size %d\n", err8, b8, size8); return 1;
        }
        puts("gl attribs ok");
    }
}
