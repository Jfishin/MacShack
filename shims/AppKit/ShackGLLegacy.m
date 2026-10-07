// Legacy desktop OpenGL (1.x client arrays, 2.0 ARB shader objects, GLSL 1.x) on OpenGL ES 3, for older GL games such
// as Chowdren ports (Cyber Shadow, run under AArchX). ShackGLGetProcAddress (ShackGL.m) asks here first.
// - Fixed function, 2D subset: client vertex/color/texcoord arrays drawn with glDrawArrays/glDrawElements through a
//   built-in program, texture unit 0 modulated by the vertex color when GL_TEXTURE_2D is enabled. No matrices: the
//   transform is identity, which is what a game that never imports the matrix calls relies on.
//   ponytail: no lighting, fog, alpha test or texture environments; add them when a game's GL log needs them.
// - ARB shader objects map onto ES programs and shaders; *EXT / *ARB names without their own mapping retry without
//   the suffix (framebuffers, blend equations, uniforms).
// - GLSL 1.x (no #version, or 1xx) becomes GLSL ES 3.00 by whole-word renames (gl_Vertex -> shack_Vertex, ...);
//   a program linked with only one stage gets the built-in other one.
// Modern guests are untouched: draws only take this path while a client array is enabled, and shaders with a
// #version of 130 or above keep ShackGL.m's translation.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGLES/ES3/gl.h>
#import <stdatomic.h>

enum { LEGACY_VERTEX_ARRAY = 0x8074, LEGACY_COLOR_ARRAY = 0x8076, LEGACY_TEXCOORD_ARRAY = 0x8078, LEGACY_TEXTURE_2D = 0x0DE1,
       ATTR_POS = 0, ATTR_COLOR = 1, ATTR_TC0 = 2, ATTR_TC1 = 3 };

// ponytail: one state for the process (single-context 2D games); per-context state when a game shares contexts.
typedef struct { GLint size; GLenum type; GLsizei stride; const void *ptr; BOOL on; } ClientArray;
static struct { ClientArray pos, color, tc[2]; GLenum clientUnit, activeUnit; BOOL tex2D[8]; BOOL anyClient; GLuint ffProg; GLint ffTexOn; } S;

static void noteAny(void) { S.anyClient = S.pos.on || S.color.on || S.tc[0].on || S.tc[1].on; }
static ClientArray *arrayFor(GLenum cap) {
    return cap == LEGACY_VERTEX_ARRAY ? &S.pos : cap == LEGACY_COLOR_ARRAY ? &S.color
         : cap == LEGACY_TEXCOORD_ARRAY ? &S.tc[S.clientUnit & 1] : NULL;
}
static void shack_glEnableClientState(GLenum cap) { ClientArray *a = arrayFor(cap); if (a) { a->on = YES; noteAny(); } }
static void shack_glDisableClientState(GLenum cap) { ClientArray *a = arrayFor(cap); if (a) { a->on = NO; noteAny(); } }
static void shack_glVertexPointer(GLint n, GLenum t, GLsizei s, const void *p) { S.pos = (ClientArray){n, t, s, p, S.pos.on}; }
static void shack_glColorPointer(GLint n, GLenum t, GLsizei s, const void *p) { S.color = (ClientArray){n, t, s, p, S.color.on}; }
static void shack_glTexCoordPointer(GLint n, GLenum t, GLsizei s, const void *p) {
    ClientArray *a = &S.tc[S.clientUnit & 1]; *a = (ClientArray){n, t, s, p, a->on};
}
static void shack_glClientActiveTexture(GLenum unit) { S.clientUnit = unit - GL_TEXTURE0; }
static void shack_glActiveTexture(GLenum unit) { S.activeUnit = unit - GL_TEXTURE0; glActiveTexture(unit); }
// Fixed-function capabilities ES does not know are recorded (GL_TEXTURE_2D) or dropped instead of raising GL errors.
static BOOL legacyCap(GLenum cap, BOOL on) {
    if (cap == LEGACY_TEXTURE_2D) { S.tex2D[S.activeUnit & 7] = on; return YES; }
    return cap == 0x0BC0 /* ALPHA_TEST */ || cap == 0x0B50 /* LIGHTING */ || cap == 0x0B60 /* FOG */ ||
           cap == 0x0B10 /* POINT_SMOOTH */ || cap == 0x0B20 /* LINE_SMOOTH */ || cap == 0x0B57 /* COLOR_MATERIAL */ ||
           cap == 0x0BA1 /* NORMALIZE */ || cap == 0x803A /* RESCALE_NORMAL */ || cap == 0x0DE0 /* TEXTURE_1D */;
}
static void shack_glEnable(GLenum cap) { if (!legacyCap(cap, YES)) glEnable(cap); }
static void shack_glDisable(GLenum cap) { if (!legacyCap(cap, NO)) glDisable(cap); }

// ---- GLSL 1.x -> GLSL ES 3.00 ----
static BOOL wordChar(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'; }
static NSString *renameWords(NSString *src, NSDictionary<NSString *, NSString *> *map) {
    NSData *in = [src dataUsingEncoding:NSUTF8StringEncoding];
    const char *s = in.bytes; size_t n = in.length, i = 0;
    NSMutableData *out = [NSMutableData dataWithCapacity:n + 256];
    while (i < n) {
        size_t j = i;
        if (wordChar(s[i]) && (i == 0 || !wordChar(s[i - 1]))) {
            while (j < n && wordChar(s[j])) j++;
            NSString *w = [[NSString alloc] initWithBytes:s + i length:j - i encoding:NSUTF8StringEncoding];
            NSString *r = w ? map[w] : nil;
            if (r) { [out appendData:[r dataUsingEncoding:NSUTF8StringEncoding]]; i = j; continue; }
        } else j = i + 1;
        [out appendBytes:s + i length:j - i]; i = j;
    }
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}
// Both stages declare the same varyings (ES links a used fragment input only to a matching vertex output). Eight
// texture coordinates and the secondary color: Feral's IndirectX GLSL (D3D9 shaders as GLSL 1.20, Batman) uses them.
static const char kVertexHead[] = "#version 300 es\nprecision highp float;\nprecision highp int;\n"
    "in vec4 shack_Vertex;\nin vec4 shack_Color;\nin vec4 shack_MultiTexCoord0;\nin vec4 shack_MultiTexCoord1;\n"
    "out vec4 shack_FrontColor;\nout vec4 shack_FrontSecondaryColor;\nout vec4 shack_TexCoord[8];\nvec4 shack_ClipVertex;\n";
static const char kFragmentHead[] = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
    "precision highp samplerCube;\nprecision highp sampler3D;\nprecision highp sampler2DShadow;\n"
    "in vec4 shack_FrontColor;\nin vec4 shack_FrontSecondaryColor;\nin vec4 shack_TexCoord[8];\n";
// GLSL 1.x's shadow lookups return vec4; ES's return float.
static const char kShadowMacros[] = "#define shadow2D(s, c) vec4(texture(s, c))\n#define shadow2DProj(s, c) vec4(textureProj(s, c))\n";
// Legacy when there is no #version or it is below 130. Returns nil for sources ShackGL.m should keep handling.
NSString *ShackGLLegacySource(NSString *src, GLenum type) {
    NSRange v = [src rangeOfString:@"#version"];
    if (v.location != NSNotFound) {
        NSScanner *sc = [NSScanner scannerWithString:[src substringFromIndex:NSMaxRange(v)]];
        int ver = 0; if ([sc scanInt:&ver] && ver >= 130) return nil;
        NSRange eol = [src rangeOfString:@"\n" options:0 range:NSMakeRange(v.location, src.length - v.location)];
        src = [src stringByReplacingCharactersInRange:NSMakeRange(v.location, (eol.location == NSNotFound ? src.length : NSMaxRange(eol)) - v.location) withString:@""];
    }
    BOOL vs = type == GL_VERTEX_SHADER;
    // Desktop extension lines (IndirectX: GL_EXT_gpu_shader4, whose integer operations ES 3.00 has) go.
    for (NSRange e; (e = [src rangeOfString:@"#extension"]).location != NSNotFound; ) {
        NSRange eol = [src rangeOfString:@"\n" options:0 range:NSMakeRange(e.location, src.length - e.location)];
        src = [src stringByReplacingCharactersInRange:NSMakeRange(e.location, (eol.location == NSNotFound ? src.length : eol.location) - e.location)
                                           withString:@""];
    }
    // Feral's IndirectX (D3D9 shaders as GLSL 1.20, each headed "// ps_3_0" or "// vs_3_0") compares float registers
    // with integer literals (r1.x != 0 ? ...), which desktop GLSL converts and ES 3.00 refuses. Its integer registers
    // (a0) are never compared, so only rN/rTemp components get a float literal.
    if ([src containsString:@"\n// ps_"] || [src containsString:@"\n// vs_"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(r[0-9]+|rTemp)(\\.[xyzw]+)\\s*(!=|==|>=|<=|<|>)\\s*(-?[0-9]+)(?![0-9.eE])" options:0 error:nil];
        src = [re stringByReplacingMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@"$1$2 $3 $4.0"];
    }
    // Legacy GLSL has no texture() built-in, so a `texture` in its source is the game's own name (a sampler): renamed.
    NSDictionary *map = @{@"attribute": @"in", @"varying": vs ? @"out" : @"in", @"texture2D": @"texture", @"texture": @"shack_texture",
        @"texture2DLod": @"textureLod", @"gl_MultiTexCoord1": @"shack_MultiTexCoord1",
        @"texture2DProj": @"textureProj", @"textureCube": @"texture", @"textureCubeLod": @"textureLod", @"texture3D": @"texture",
        @"gl_Vertex": @"shack_Vertex", @"gl_Color": vs ? @"shack_Color" : @"shack_FrontColor",
        @"gl_SecondaryColor": @"shack_FrontSecondaryColor", @"gl_FrontSecondaryColor": @"shack_FrontSecondaryColor",
        @"gl_ClipVertex": @"shack_ClipVertex", @"gl_FragData": @"shack_FragData",
        @"gl_MultiTexCoord0": @"shack_MultiTexCoord0", @"gl_FrontColor": @"shack_FrontColor", @"gl_TexCoord": @"shack_TexCoord",
        @"gl_FragColor": @"shack_FragColor", @"gl_ModelViewProjectionMatrix": @"mat4(1.0)", @"ftransform": @"shack_ftransform"};
    // One fragment output, gl_FragColor's, unless the shader writes gl_FragData (ES needs locations for more than one).
    int fragData = 0;
    for (NSRange r = NSMakeRange(0, src.length); (r = [src rangeOfString:@"gl_FragData[" options:0 range:r]).location != NSNotFound;
         r = NSMakeRange(NSMaxRange(r), src.length - NSMaxRange(r))) {
        int i = [src substringFromIndex:NSMaxRange(r)].intValue;
        if (i + 1 > fragData) fragData = i + 1 > 8 ? 8 : i + 1;
    }
    NSString *out = fragData ? [NSString stringWithFormat:@"layout(location = 0) out vec4 shack_FragData[%d];\n", fragData]
                             : @"out vec4 shack_FragColor;\n";
    NSString *body = renameWords(src, map);
    // Feral's context probe has no #version but uses gl_VertexID with desktop int-to-float promotion.
    // ES 3.00 needs explicit conversions. Keep the integer product intact before converting its result;
    // changing every gl_VertexID to float would break indexing and bit operations in other shaders.
    if (vs) {
        body = [body stringByReplacingOccurrencesOfString:@"-3+0.5*gl_VertexID" withString:@"-3.0+0.5*float(gl_VertexID)"];
        body = [body stringByReplacingOccurrencesOfString:@"1.0-(gl_VertexID-1-3)*(gl_VertexID-1-3)"
                                              withString:@"1.0-float((gl_VertexID-1-3)*(gl_VertexID-1-3))"];
    }
    return vs ? [NSString stringWithFormat:@"%s%s#define shack_ftransform() shack_Vertex\n%@", kVertexHead, kShadowMacros, body]
              : [NSString stringWithFormat:@"%s%@%s%@", kFragmentHead, out, kShadowMacros, body];
}
static GLuint compile(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type); glShaderSource(sh, 1, &src, NULL); glCompileShader(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024] = ""; glGetShaderInfoLog(sh, sizeof log, NULL, log); NSLog(@"[ShackGL] legacy built-in shader: %s", log); }
    return sh;
}
static const char kDefaultVS[] = "void main() { gl_Position = shack_Vertex; shack_FrontColor = shack_Color; shack_TexCoord[0] = shack_MultiTexCoord0; shack_TexCoord[1] = shack_MultiTexCoord1; }\n";
static GLuint builtin(GLenum type) {
    NSString *body = type == GL_VERTEX_SHADER ? @(kDefaultVS)
        : @"uniform sampler2D shack_Tex0;\nuniform int shack_TexOn;\nvoid main() { shack_FragColor = shack_FrontColor * (shack_TexOn != 0 ? texture(shack_Tex0, shack_TexCoord[0].xy) : vec4(1.0)); }\n";
    NSString *head = type == GL_VERTEX_SHADER ? @(kVertexHead) : [@(kFragmentHead) stringByAppendingString:@"out vec4 shack_FragColor;\n"];
    return compile(type, [head stringByAppendingString:body].UTF8String);
}
static void bindLegacyAttribs(GLuint prog) {
    glBindAttribLocation(prog, ATTR_POS, "shack_Vertex"); glBindAttribLocation(prog, ATTR_COLOR, "shack_Color");
    glBindAttribLocation(prog, ATTR_TC0, "shack_MultiTexCoord0"); glBindAttribLocation(prog, ATTR_TC1, "shack_MultiTexCoord1");
}
// A legacy program may carry only a fragment (or only a vertex) shader: ES links neither, so the other is built in.
static void shack_glLinkProgram(GLuint prog) {
    GLuint sh[8]; GLsizei n = 0; BOOL hasVS = NO, hasFS = NO;
    glGetAttachedShaders(prog, 8, &n, sh);
    for (GLsizei i = 0; i < n; i++) { GLint t = 0; glGetShaderiv(sh[i], GL_SHADER_TYPE, &t); hasVS |= t == GL_VERTEX_SHADER; hasFS |= t == GL_FRAGMENT_SHADER; }
    if (n && !hasVS) glAttachShader(prog, builtin(GL_VERTEX_SHADER));
    if (n && !hasFS) glAttachShader(prog, builtin(GL_FRAGMENT_SHADER));
    bindLegacyAttribs(prog);
    glLinkProgram(prog);
    GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) { char log[1024] = ""; glGetProgramInfoLog(prog, sizeof log, NULL, log); NSLog(@"[ShackGL] link failed: %s", log); }
}

// ---- drawing through client arrays ----
static void attrib(GLuint loc, const ClientArray *a, BOOL on, const GLfloat *fallback) {
    if (on && a->ptr) {
        glEnableVertexAttribArray(loc);
        glVertexAttribPointer(loc, a->size, a->type, a->type == GL_UNSIGNED_BYTE, a->stride, a->ptr);
    } else { glDisableVertexAttribArray(loc); glVertexAttrib4fv(loc, fallback); }
}
static void beginClientDraw(GLint *restoreProg) {
    GLint vao = 0; glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
    if (vao) glBindVertexArray(0);   // ES reads client memory only with the default vertex array object
    static const GLfloat white[4] = {1, 1, 1, 1}, zero[4] = {0, 0, 0, 1};
    attrib(ATTR_POS, &S.pos, S.pos.on, zero); attrib(ATTR_COLOR, &S.color, S.color.on, white); attrib(ATTR_TC0, &S.tc[0], S.tc[0].on, zero);
    attrib(ATTR_TC1, &S.tc[1], S.tc[1].on, zero);
    glGetIntegerv(GL_CURRENT_PROGRAM, restoreProg);
    if (*restoreProg) return;
    if (!S.ffProg) {
        S.ffProg = glCreateProgram();
        glAttachShader(S.ffProg, builtin(GL_VERTEX_SHADER)); glAttachShader(S.ffProg, builtin(GL_FRAGMENT_SHADER));
        bindLegacyAttribs(S.ffProg); glLinkProgram(S.ffProg);
        glUseProgram(S.ffProg);
        glUniform1i(glGetUniformLocation(S.ffProg, "shack_Tex0"), 0);
        S.ffTexOn = glGetUniformLocation(S.ffProg, "shack_TexOn");
        NSLog(@"[ShackGL] fixed-function emulation in use (client arrays)");
    }
    glUseProgram(S.ffProg);
    glUniform1i(S.ffTexOn, S.tex2D[0]);
}
static void shack_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    if (!S.anyClient) { glDrawArrays(mode, first, count); return; }
    GLint prog; beginClientDraw(&prog); glDrawArrays(mode, first, count); if (!prog) glUseProgram(0);
}
static void shack_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *idx) {
    if (!S.anyClient) { glDrawElements(mode, count, type, idx); return; }
    GLint prog; beginClientDraw(&prog); glDrawElements(mode, count, type, idx); if (!prog) glUseProgram(0);
}

// ---- ARB shader objects (GLhandleARB is a pointer on macOS) ----
extern void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths);
static void *shack_glCreateShaderObjectARB(GLenum type) { return (void *)(uintptr_t)glCreateShader(type); }
static void *shack_glCreateProgramObjectARB(void) { return (void *)(uintptr_t)glCreateProgram(); }
static void shack_glAttachObjectARB(void *p, void *s) { glAttachShader((GLuint)(uintptr_t)p, (GLuint)(uintptr_t)s); }
static void shack_glDetachObjectARB(void *p, void *s) { glDetachShader((GLuint)(uintptr_t)p, (GLuint)(uintptr_t)s); }
static void shack_glDeleteObjectARB(void *o) { GLuint h = (GLuint)(uintptr_t)o; if (glIsShader(h)) glDeleteShader(h); else glDeleteProgram(h); }
static void shack_glUseProgramObjectARB(void *p) { glUseProgram((GLuint)(uintptr_t)p); }
static void shack_glLinkProgramARB(void *p) { shack_glLinkProgram((GLuint)(uintptr_t)p); }
static void shack_glCompileShader(GLuint sh) {
    glCompileShader(sh);
    GLint ok = 1; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    static atomic_int logged;
    if (ok || atomic_fetch_add(&logged, 1) >= 6) return;
    GLint len = 0; glGetShaderiv(sh, GL_SHADER_SOURCE_LENGTH, &len);
    char *src = calloc((size_t)len + 1, 1), log[1024] = "";
    glGetShaderSource(sh, len + 1, NULL, src); glGetShaderInfoLog(sh, sizeof log, NULL, log);
    NSLog(@"[ShackGL] shader %u failed: %s\n---- source as compiled ----\n%s\n----", sh, log, src);
    free(src);
}
static void shack_glCompileShaderARB(void *s) { shack_glCompileShader((GLuint)(uintptr_t)s); }
static void shack_glShaderSourceARB(void *s, GLsizei n, const GLchar *const *str, const GLint *len) { ShackGLShaderSource((GLuint)(uintptr_t)s, n, str, len); }
// COMPILE_STATUS/LINK_STATUS/INFO_LOG_LENGTH share values with the _ARB object queries.
static void shack_glGetObjectParameterivARB(void *o, GLenum pname, GLint *out) {
    GLuint h = (GLuint)(uintptr_t)o;
    if (pname == 0x8B4E /* OBJECT_TYPE */) { *out = glIsShader(h) ? 0x8B48 /* SHADER_OBJECT */ : 0x8B40 /* PROGRAM_OBJECT */; return; }
    if (glIsShader(h)) glGetShaderiv(h, pname, out); else glGetProgramiv(h, pname, out);
}
static void shack_glGetInfoLogARB(void *o, GLsizei max, GLsizei *len, GLchar *log) {
    GLuint h = (GLuint)(uintptr_t)o;
    if (glIsShader(h)) glGetShaderInfoLog(h, max, len, log); else glGetProgramInfoLog(h, max, len, log);
}
static GLint shack_glGetUniformLocationARB(void *p, const GLchar *name) { return glGetUniformLocation((GLuint)(uintptr_t)p, name); }

// The ES extensions plus the desktop names these emulations stand behind (S3TC/RGTC: decoded in ShackGLTexture.m).
const GLubyte *ShackGLLegacyExtensions(void) {
    static _Atomic(char *) all;   // cached once ES answered (it returns NULL with no context current)
    char *cached = atomic_load(&all);
    if (cached) return (const GLubyte *)cached;
    const char *es = (const char *)glGetString(GL_EXTENSIONS);
    char *s = NULL;
    asprintf(&s, "%s GL_ARB_multitexture GL_ARB_shader_objects GL_ARB_vertex_shader GL_ARB_fragment_shader "
             "GL_ARB_shading_language_100 GL_ARB_texture_non_power_of_two GL_ARB_vertex_buffer_object GL_EXT_framebuffer_object "
             "GL_ARB_framebuffer_object GL_EXT_blend_equation_separate GL_EXT_blend_func_separate GL_EXT_blend_minmax "
             "GL_EXT_texture_compression_s3tc GL_EXT_texture_sRGB GL_ARB_texture_compression_rgtc", es ? es : "");
    if (!es) return (const GLubyte *)s;   // ponytail: leaks this one uncached string per early call
    char *expected = NULL;
    if (!atomic_compare_exchange_strong(&all, &expected, s)) { free(s); s = expected; }
    return (const GLubyte *)s;
}

// GL 3 style queries (SDL_GL_ExtensionSupported on a "3.3" context reads these, not glGetString): the same extras.
static const char *const kExtra[] = { "GL_ARB_multitexture", "GL_ARB_shader_objects", "GL_ARB_vertex_shader",
    "GL_ARB_fragment_shader", "GL_ARB_shading_language_100", "GL_ARB_texture_non_power_of_two", "GL_ARB_vertex_buffer_object",
    "GL_EXT_framebuffer_object", "GL_ARB_framebuffer_object", "GL_EXT_blend_equation_separate", "GL_EXT_blend_func_separate",
    "GL_EXT_blend_minmax", "GL_EXT_texture_compression_s3tc", "GL_EXT_texture_sRGB", "GL_ARB_texture_compression_rgtc" };
enum { EXTRA_N = sizeof kExtra / sizeof *kExtra };
static void shack_glGetIntegerv(GLenum pname, GLint *out) {
    // The version the GL_VERSION string reports (3.3, core profile), not ES's 3.0: Unity refuses below 3.2.
    if (out && (pname == GL_MAJOR_VERSION || pname == GL_MINOR_VERSION)) { *out = 3; return; }
    if (out && pname == 0x9126) { *out = 1; return; }   // GL_CONTEXT_PROFILE_MASK: GL_CONTEXT_CORE_PROFILE_BIT
    glGetIntegerv(pname, out);
    if (pname == GL_NUM_EXTENSIONS && out) *out += EXTRA_N;
}
static const GLubyte *shack_glGetStringi(GLenum name, GLuint i) {
    GLint es = 0;
    if (name != GL_EXTENSIONS) return glGetStringi(name, i);
    glGetIntegerv(GL_NUM_EXTENSIONS, &es);
    return i < (GLuint)es ? glGetStringi(name, i) : i < (GLuint)es + EXTRA_N ? (const GLubyte *)kExtra[i - (GLuint)es] : NULL;
}

void *ShackGLLegacyProc(const char *name) {
    static const struct { const char *name; void *fn; } t[] = {
        {"glEnableClientState", shack_glEnableClientState}, {"glDisableClientState", shack_glDisableClientState},
        {"glVertexPointer", shack_glVertexPointer}, {"glColorPointer", shack_glColorPointer}, {"glTexCoordPointer", shack_glTexCoordPointer},
        {"glClientActiveTexture", shack_glClientActiveTexture}, {"glClientActiveTextureARB", shack_glClientActiveTexture},
        {"glActiveTexture", shack_glActiveTexture}, {"glActiveTextureARB", shack_glActiveTexture},
        {"glEnable", shack_glEnable}, {"glDisable", shack_glDisable},
        {"glGetIntegerv", shack_glGetIntegerv}, {"glGetStringi", shack_glGetStringi},
        {"glCompileShader", shack_glCompileShader}, {"glDrawArrays", shack_glDrawArrays}, {"glDrawElements", shack_glDrawElements}, {"glLinkProgram", shack_glLinkProgram},
        {"glCreateShaderObjectARB", shack_glCreateShaderObjectARB}, {"glCreateProgramObjectARB", shack_glCreateProgramObjectARB},
        {"glAttachObjectARB", shack_glAttachObjectARB}, {"glDetachObjectARB", shack_glDetachObjectARB},
        {"glDeleteObjectARB", shack_glDeleteObjectARB}, {"glUseProgramObjectARB", shack_glUseProgramObjectARB},
        {"glLinkProgramARB", shack_glLinkProgramARB}, {"glCompileShaderARB", shack_glCompileShaderARB},
        {"glShaderSourceARB", shack_glShaderSourceARB}, {"glGetObjectParameterivARB", shack_glGetObjectParameterivARB},
        {"glGetInfoLogARB", shack_glGetInfoLogARB}, {"glGetUniformLocationARB", shack_glGetUniformLocationARB},
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; i++) if (!strcmp(name, t[i].name)) return t[i].fn;
    return NULL;
}
