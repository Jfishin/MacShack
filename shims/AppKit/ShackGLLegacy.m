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
#import <OpenGLES/EAGL.h>
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
// Legacy when there is no #version or it is below 130; nil otherwise.
static NSString *legacySource(NSString *src, GLenum type) {
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
// GLSL ES has no default precision for these samplers; desktop GLSL needs none (Godot 3 declares sampler2DArray).
static const char kESHead[] = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
    "precision highp sampler3D;\nprecision highp samplerCube;\nprecision highp sampler2DArray;\nprecision highp sampler2DShadow;\n"
    "precision highp samplerCubeShadow;\nprecision highp sampler2DArrayShadow;\nprecision highp isampler2D;\n"
    "precision highp usampler2D;\nprecision highp isampler3D;\nprecision highp usampler3D;\nprecision highp isampler2DArray;\n"
    "precision highp usampler2DArray;\nprecision highp isamplerCube;\nprecision highp usamplerCube;\n";
// Any desktop GLSL source as GLSL ES 3.00 (ShackGL.m's glShaderSource): 1.x through the renames above, 130 and up with
// ES's version line and sampler precisions.
static NSString *esSource(NSString *src, GLenum type);
// User clip planes: gl_ClipDistance (GLSL 1.30+) is ES 3.0's only through GL_APPLE_clip_distance, which iOS has (Feral's
// light vertex shaders, Batman); its directive goes right after the version line.
NSString *ShackGLESSource(NSString *src, GLenum type) {
    NSString *es = esSource(src, type);
    if (type != GL_VERTEX_SHADER || ![es containsString:@"gl_ClipDistance"]) return es;
    NSRange eol = [es rangeOfString:@"\n"];
    return eol.location == NSNotFound ? es
        : [es stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(eol), 0) withString:@"#extension GL_APPLE_clip_distance : require\n"];
}
static NSString *esSource(NSString *src, GLenum type) {
    // Feral's IndirectX (D3D9 shaders as GLSL, each headed "// ps_3_0" or "// vs_3_0"; Batman) compares float registers
    // with integer literals (r1.x != 0 ? ...), which desktop GLSL converts and ES 3.00 refuses, in its GLSL 1.20 and
    // its newer GLSL alike (it writes the newer when the context reports GLSL 3.30, as ShackGL's does). Its integer
    // registers (a0) are never compared, so only rN/rTemp components get a float literal.
    NSString *lines = [@"\n" stringByAppendingString:src];
    if ([lines containsString:@"\n// ps_"] || [lines containsString:@"\n// vs_"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(r[0-9]+|rTemp)(\\.[xyzw]+)\\s*(!=|==|>=|<=|<|>)\\s*(-?[0-9]+)(?![0-9.eE])" options:0 error:nil];
        src = [re stringByReplacingMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@"$1$2 $3 $4.0"];
    }
    NSString *legacy = legacySource(src, type);
    if (legacy) return legacy;
    // GLSL 3.30 and GLSL ES 3.00 share what raylib's shaders use; ES needs its own version line and precisions.
    NSRange v = [src rangeOfString:@"#version"];
    NSRange eol = v.location == NSNotFound ? v : [src rangeOfString:@"\n" options:0 range:NSMakeRange(v.location, src.length - v.location)];
    if (eol.location != NSNotFound && ![[src substringWithRange:NSMakeRange(v.location, eol.location - v.location)] containsString:@" es"]) {
        src = [src stringByReplacingCharactersInRange:NSMakeRange(v.location, NSMaxRange(eol) - v.location) withString:@(kESHead)];
        // Desktop extension lines (Unity's GLSL 150: GL_ARB_explicit_attrib_location : require) are errors in ES,
        // whose 3.00 core already has what they enable.
        NSRegularExpression *ext = [NSRegularExpression regularExpressionWithPattern:@"#extension GL_ARB_[^\n]*" options:0 error:nil];
        src = [ext stringByReplacingMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@""];
    }
    // Godot 3's desktop prelude defines GLES_OVER_GL, and its shaders branch on it; without it they take the path
    // Godot itself runs on mobile GLES3.
    NSRange g = [src rangeOfString:@"#define GLES_OVER_GL\n"];
    return g.location == NSNotFound ? src : [src stringByReplacingCharactersInRange:g withString:@""];
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
// Desktop GL links every attached shader of a stage together, ES one per stage. Feral's IndirectX (Batman) attaches
// its alphaTest() as a second fragment shader next to the one that calls it. The extra ones wait here, and each link
// compiles the stage's shader joined with them in its place, then puts the game's own back. ponytail: GLSL 130+ extras
// only (their ES head is version and precision lines); a deleted program's list is never dropped.
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *extras(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
static GLenum shaderType(GLuint sh) { GLint t = 0; glGetShaderiv(sh, GL_SHADER_TYPE, &t); return (GLenum)t; }
static GLuint attachedOfType(GLuint prog, GLenum type) {
    GLuint sh[8]; GLsizei n = 0; glGetAttachedShaders(prog, 8, &n, sh);
    for (GLsizei i = 0; i < n; i++) if (shaderType(sh[i]) == type) return sh[i];
    return 0;
}
static void shack_glAttachShader(GLuint prog, GLuint sh) {
    if (!attachedOfType(prog, shaderType(sh))) { glAttachShader(prog, sh); return; }
    @synchronized (extras()) {
        NSMutableArray *x = extras()[@(prog)] ?: (extras()[@(prog)] = [NSMutableArray array]);
        if (![x containsObject:@(sh)]) [x addObject:@(sh)];
    }
}
static void shack_glDetachShader(GLuint prog, GLuint sh) {
    @synchronized (extras()) {
        NSMutableArray<NSNumber *> *x = extras()[@(prog)];
        if ([x containsObject:@(sh)]) { [x removeObject:@(sh)]; return; }
        glDetachShader(prog, sh);
        for (NSNumber *e in x) if (shaderType(e.unsignedIntValue) == shaderType(sh)) {   // the next one takes its place
            [x removeObject:e]; glAttachShader(prog, e.unsignedIntValue); break;
        }
    }
}
static NSString *shaderText(GLuint sh) {
    GLint n = 0; glGetShaderiv(sh, GL_SHADER_SOURCE_LENGTH, &n);
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)n + 1];
    glGetShaderSource(sh, n + 1, NULL, d.mutableBytes);
    return @((const char *)d.bytes);
}
// The stage's shader joined with its extras, compiled; 0 when it has none.
static GLuint joined(GLuint prog, GLenum type, GLuint *base) {
    NSMutableString *src = nil;
    @synchronized (extras()) {
        for (NSNumber *e in extras()[@(prog)]) {
            if (shaderType(e.unsignedIntValue) != type || !(*base = attachedOfType(prog, type))) continue;
            if (!src) src = [shaderText(*base) mutableCopy];
            for (NSString *line in [shaderText(e.unsignedIntValue) componentsSeparatedByString:@"\n"])
                if (![line hasPrefix:@"#version"] && ![line hasPrefix:@"precision "]) [src appendFormat:@"\n%@", line];
        }
    }
    if (!src) return 0;
    GLuint sh = glCreateShader(type); const GLchar *s = src.UTF8String;
    glShaderSource(sh, 1, &s, NULL); glCompileShader(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024] = ""; glGetShaderInfoLog(sh, sizeof log, NULL, log); NSLog(@"[ShackGL] joined shader failed: %s", log); }
    return sh;
}
// A legacy program may carry only a fragment (or only a vertex) shader: ES links neither, so the other is built in.
static void shack_glLinkProgram(GLuint prog) {
    GLuint sh[8]; GLsizei n = 0; BOOL hasVS = NO, hasFS = NO;
    glGetAttachedShaders(prog, 8, &n, sh);
    for (GLsizei i = 0; i < n; i++) { GLint t = 0; glGetShaderiv(sh[i], GL_SHADER_TYPE, &t); hasVS |= t == GL_VERTEX_SHADER; hasFS |= t == GL_FRAGMENT_SHADER; }
    if (n && !hasVS) glAttachShader(prog, builtin(GL_VERTEX_SHADER));
    if (n && !hasFS) glAttachShader(prog, builtin(GL_FRAGMENT_SHADER));
    bindLegacyAttribs(prog);
    GLuint base[2] = {0, 0}, join[2] = { joined(prog, GL_VERTEX_SHADER, &base[0]), joined(prog, GL_FRAGMENT_SHADER, &base[1]) };
    for (int i = 0; i < 2; i++) if (join[i]) { glDetachShader(prog, base[i]); glAttachShader(prog, join[i]); }
    glLinkProgram(prog);
    for (int i = 0; i < 2; i++) if (join[i]) { glDetachShader(prog, join[i]); glDeleteShader(join[i]); glAttachShader(prog, base[i]); }
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
void (*ShackGLTraceHook)(const char *what);   // ShackGL.m's frame tracer (SHACK_GL_DRAWTRACE), after each draw
static void shack_glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    if (!S.anyClient) glDrawArrays(mode, first, count);
    else { GLint prog; beginClientDraw(&prog); glDrawArrays(mode, first, count); if (!prog) glUseProgram(0); }
    if (ShackGLTraceHook) ShackGLTraceHook("glDrawArrays");
}
static void shack_glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *idx) {
    if (!S.anyClient) glDrawElements(mode, count, type, idx);
    else { GLint prog; beginClientDraw(&prog); glDrawElements(mode, count, type, idx); if (!prog) glUseProgram(0); }
    if (ShackGLTraceHook) ShackGLTraceHook("glDrawElements");
}

// ---- ARB shader objects (GLhandleARB is a pointer on macOS) ----
extern void ShackGLShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths);
static void *shack_glCreateShaderObjectARB(GLenum type) { return (void *)(uintptr_t)glCreateShader(type); }
// Desktop core GL lets an enabled attribute have no buffer and a NULL pointer; iOS's GLEngine fetches it as a client
// array at address 0 and faults (Batman's render thread, Feral's unfed D3D streams). Such an
// attribute reads a buffer of zeros instead (one per share group). ponytail: 4 KB, enough for the stride-0 streams seen;
// a strided one reads past it on the GPU, which gives zeros or undefined values, not a fault.
static GLuint zeroBuffer(void) {
    static NSMutableDictionary<NSValue *, NSNumber *> *buffers;
    NSValue *group = [NSValue valueWithNonretainedObject:EAGLContext.currentContext.sharegroup];
    @synchronized (EAGLContext.class) {
        if (!buffers) buffers = [NSMutableDictionary dictionary];
        NSNumber *b = buffers[group];
        if (b) return b.unsignedIntValue;
        GLuint name = 0; GLint was = 0;
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &was);
        glGenBuffers(1, &name); glBindBuffer(GL_ARRAY_BUFFER, name);
        void *zeros = calloc(1, 4096); glBufferData(GL_ARRAY_BUFFER, 4096, zeros, GL_STATIC_DRAW); free(zeros);
        glBindBuffer(GL_ARRAY_BUFFER, (GLuint)was);
        buffers[group] = @(name);
        return name;
    }
}
static BOOL unfed(const void *p) {   // NULL with no array buffer bound: bind the zero buffer for the pointer call
    if (p) return NO;
    GLint b = 0; glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &b);
    if (b) return NO;
    glBindBuffer(GL_ARRAY_BUFFER, zeroBuffer());
    return YES;
}
// D3DCOLOR streams: desktop GL takes size GL_BGRA (ARB_vertex_array_bgra) and reads B,G,R,A; ES refuses it (Batman's
// vertex colors never arrived). They come as 4 normalized bytes. ponytail: red and blue stay swapped; a per-attribute
// swizzle in the vertex shader fixes that when a game's colors show it.
static void shack_glVertexAttribPointer(GLuint i, GLint size, GLenum type, GLboolean norm, GLsizei stride, const void *p) {
    if (size == 0x80E1) {
        size = 4;
        static atomic_int said;
        if (!atomic_fetch_add(&said, 1)) NSLog(@"[ShackGL] GL_BGRA vertex attributes read as RGBA (red and blue swapped)");
    }
    BOOL z = unfed(p);
    glVertexAttribPointer(i, size, type, norm, stride, p);
    if (z) glBindBuffer(GL_ARRAY_BUFFER, 0);
}
static void shack_glVertexAttribIPointer(GLuint i, GLint size, GLenum type, GLsizei stride, const void *p) {
    BOOL z = unfed(p);
    glVertexAttribIPointer(i, size, type, stride, p);
    if (z) glBindBuffer(GL_ARRAY_BUFFER, 0);
}

// Enabled and never given a pointer (GL's defaults: buffer 0, NULL, 4 floats; Batman's attributes 3-6): the same zero
// buffer. A client array the guest points at afterwards replaces it as usual.
static void shack_glEnableVertexAttribArray(GLuint i) {
    glEnableVertexAttribArray(i);
    GLint buf = 0; glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buf);
    void *p = NULL; if (!buf) glGetVertexAttribPointerv(i, GL_VERTEX_ATTRIB_ARRAY_POINTER, &p);
    if (buf || p) return;
    GLint size = 4, type = GL_FLOAT, norm = 0, stride = 0, integer = 0, was = 0;
    glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size); glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_TYPE, &type);
    glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &norm); glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &stride);
    glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_INTEGER, &integer); glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &was);
    glBindBuffer(GL_ARRAY_BUFFER, zeroBuffer());
    if (integer) glVertexAttribIPointer(i, size, (GLenum)type, stride, NULL);
    else glVertexAttribPointer(i, size, (GLenum)type, (GLboolean)norm, stride, NULL);
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)was);
    static atomic_int said;
    if (atomic_fetch_add(&said, 1) < 4) NSLog(@"[ShackGL] attribute %u enabled with no data: it reads zeros", i);
}
// A buffer deleted while the current VAO's attributes still use it leaves them buffer 0 with their offset, which GLEngine
// also fetches as a client array (Feral deletes its per-draw stream buffers so). Those attributes move to the zero buffer.
static void shack_glDeleteBuffers(GLsizei n, const GLuint *names) {
    enum { N = 16 };
    struct { GLint size, type, norm, stride, integer; } a[N];
    BOOL hit[N] = {NO}, any = NO;
    GLint max = 0; glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &max); if (max > N) max = N;
    for (GLint i = 0; i < max; i++) {
        GLint buf = 0; glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buf);
        for (GLsizei k = 0; buf && k < n && !hit[i]; k++) hit[i] = names[k] == (GLuint)buf;
        if (!hit[i]) continue;
        any = YES;
        glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a[i].size);
        glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a[i].type);
        glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a[i].norm);
        glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a[i].stride);
        glGetVertexAttribiv((GLuint)i, GL_VERTEX_ATTRIB_ARRAY_INTEGER, &a[i].integer);
    }
    glDeleteBuffers(n, names);
    if (!any) return;
    GLint was = 0; glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &was);
    glBindBuffer(GL_ARRAY_BUFFER, zeroBuffer());
    for (GLint i = 0; i < max; i++) {
        if (!hit[i]) continue;
        if (a[i].integer) glVertexAttribIPointer((GLuint)i, a[i].size, (GLenum)a[i].type, a[i].stride, NULL);
        else glVertexAttribPointer((GLuint)i, a[i].size, (GLenum)a[i].type, (GLboolean)a[i].norm, a[i].stride, NULL);
    }
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)was);
    static atomic_int said;
    if (atomic_fetch_add(&said, 1) < 4) {
        NSMutableString *m = [NSMutableString string];
        for (GLint i = 0; i < max; i++) if (hit[i]) [m appendFormat:@" %d", i];
        NSLog(@"[ShackGL] a deleted buffer still fed attribute(s)%@: they read zeros now", m);
    }
}

// CGL's surface backing size (kCGLCPSurfaceBackingSize, enabled by kCGLCESurfaceBackingSize): the default framebuffer is
// w x h pixels whatever the view's size, and the window server stretches it to fill the view (Feral's windowed
// resolution: Batman asks for 960x720). ShackGL.m's context uses an offscreen framebuffer of that size as its default
// and stretches it onto the layer's at each present. names: framebuffer, color, depth-stencil (0 until the first fit).
GLuint ShackGLSurfaceFit(GLuint names[3], GLint size[2], GLint w, GLint h) {
    if (!names[0]) { glGenFramebuffers(1, &names[0]); glGenRenderbuffers(2, &names[1]); }
    if (size[0] == w && size[1] == h) return names[0];
    GLint fb = 0, rb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb); glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, names[1]); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
    glBindRenderbuffer(GL_RENDERBUFFER, names[2]); glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
    glBindFramebuffer(GL_FRAMEBUFFER, names[0]);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, names[1]);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, names[2]);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)fb); glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)rb);
    size[0] = w; size[1] = h;
    NSLog(@"[ShackGL] surface backing size %dx%d", w, h);
    return names[0];
}
void ShackGLSurfaceBlit(const GLuint names[3], const GLint size[2], GLuint dst, GLint dw, GLint dh) {
    GLint r = 0, d = 0; glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &r); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &d);
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);   // a blit is scissored; the present is the whole surface
    if (scissor) glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, names[0]); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst);
    glBlitFramebuffer(0, 0, size[0], size[1], 0, 0, dw, dh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)r); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)d);
    if (scissor) glEnable(GL_SCISSOR_TEST);
}

// Occlusion queries (GL_ARB_occlusion_query, reported above): ES 3 has only "any samples passed", so a sample count is
// 0 or 1, which is what visibility tests read (Batman's IndirectX gives its D3D9 queries no GL query without the
// extension, then issues them through NULL). ES has no counter-bits query and no glGetQueryObjectiv.
enum { QUERY_SAMPLES_PASSED = 0x8914, QUERY_COUNTER_BITS = 0x8864 };
static GLenum esQuery(GLenum target) { return target == QUERY_SAMPLES_PASSED ? GL_ANY_SAMPLES_PASSED : target; }
static void shack_glBeginQuery(GLenum target, GLuint id) { glBeginQuery(esQuery(target), id); }
static void shack_glEndQuery(GLenum target) { glEndQuery(esQuery(target)); }
static void shack_glGetQueryiv(GLenum target, GLenum pname, GLint *out) {
    if (pname == QUERY_COUNTER_BITS) { *out = target == QUERY_SAMPLES_PASSED || target == GL_ANY_SAMPLES_PASSED ? 32 : 0; return; }
    glGetQueryiv(esQuery(target), pname, out);
}
static void shack_glGetQueryObjectiv(GLuint id, GLenum pname, GLint *out) {
    GLuint v = 0; glGetQueryObjectuiv(id, pname, &v); *out = (GLint)v;
}

// Texture parameters given as floats: desktop GL converts an enum or integer one (Feral sets its swizzles so, emulating
// D3D9 L8/A8 with GL_RED textures); iOS's ES driver left those swizzles unapplied (Batman's menu: opaque red boxes).
// Only the float-valued ones stay floats.
static BOOL floatTexParam(GLenum p) {   // MIN_LOD, MAX_LOD, MAX_ANISOTROPY, LOD_BIAS, BORDER_COLOR
    return p == 0x813A || p == 0x813B || p == 0x84FE || p == 0x8501 || p == 0x1004;
}
static void shack_glTexParameterf(GLenum t, GLenum p, GLfloat v) {
    if (floatTexParam(p)) glTexParameterf(t, p, v); else glTexParameteri(t, p, (GLint)v);
}
static void shack_glTexParameterfv(GLenum t, GLenum p, const GLfloat *v) {
    if (floatTexParam(p)) { glTexParameterfv(t, p, v); return; }
    if (p == 0x8E46) { for (GLenum i = 0; i < 4; i++) glTexParameteri(t, GL_TEXTURE_SWIZZLE_R + i, (GLint)v[i]); return; }   // SWIZZLE_RGBA
    glTexParameteri(t, p, (GLint)v[0]);
}

// glColorMaski (per draw buffer, GL 3.0; ES only from 3.2): buffer 0's mask is ES 3.0's glColorMask. Scaleform (Batman's
// menus) draws its clip masks with color writes off; ignored, they showed as solid boxes. ponytail: the masks of draw
// buffers 1+ are dropped; per-buffer state comes when a game writes several targets with different masks.
static void shack_glColorMaski(GLuint buf, GLboolean r, GLboolean g, GLboolean b, GLboolean a) { if (!buf) glColorMask(r, g, b, a); }

// macOS games upload BGRA (CoronaCards: GL_BGRA with GL_UNSIGNED_INT_8_8_8_8, Apple's fast path; Batman: 8_8_8_8_REV
// with GL_UNPACK_ROW_LENGTH). ES 3.0 has neither GL_BGRA as an upload format nor the packed 8_8_8_8 types, so those
// uploads (and RGBA in the non-REV packed type) are repacked as tight RGBA (or RGB) bytes, reading rows by the unpack
// row length, skips and alignment; the caller frees the result and sends it through ShackGLUnpackTight. An unpack
// buffer's upload is passed on as is.
void *ShackGLRepack(GLsizei w, GLsizei h, GLenum *fmt, GLenum *type, const void **d) {
    if (!*d || w <= 0 || h <= 0) return NULL;
    BOOL bgra = *fmt == 0x80E1, bgr = *fmt == 0x80E0, rgba = *fmt == GL_RGBA;
    if (rgba && *type == 0x8367) { *type = GL_UNSIGNED_BYTE; return NULL; }   // 8_8_8_8_REV: memory is R,G,B,A already
    BOOL packed = *type == 0x8035, ok = ((bgra || rgba) && packed) || (bgra && (*type == 0x8367 || *type == GL_UNSIGNED_BYTE)) || (bgr && *type == GL_UNSIGNED_BYTE);
    if (!ok) return NULL;
    GLint align = 4, row = 0, skipP = 0, skipR = 0, pbo = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (pbo || align < 1 || row < 0 || skipP < 0 || skipR < 0) return NULL;
    size_t bpp = bgr ? 3 : 4, stride = ((size_t)(row ? row : w) * bpp + (size_t)align - 1) / (size_t)align * (size_t)align;
    const uint8_t *base = (const uint8_t *)*d + (size_t)skipR * stride + (size_t)skipP * bpp;
    uint8_t *out = malloc((size_t)w * (size_t)h * bpp);
    if (!out) return NULL;
    for (GLsizei y = 0; y < h; y++) {
        const uint8_t *src = base + (size_t)y * stride;
        uint8_t *dst = out + (size_t)y * (size_t)w * bpp;
        for (GLsizei x = 0; x < w; x++, src += bpp, dst += bpp) {
            if (bgr || (bgra && !packed)) { dst[0] = src[2]; dst[1] = src[1]; dst[2] = src[0]; if (!bgr) dst[3] = src[3]; continue; }
            uint32_t v; memcpy(&v, src, 4);
            if (bgra) { dst[0] = (uint8_t)(v >> 8); dst[1] = (uint8_t)(v >> 16); dst[2] = (uint8_t)(v >> 24); dst[3] = (uint8_t)v; }
            else { dst[0] = (uint8_t)(v >> 24); dst[1] = (uint8_t)(v >> 16); dst[2] = (uint8_t)(v >> 8); dst[3] = (uint8_t)v; }
        }
    }
    *fmt = bgr ? GL_RGB : GL_RGBA; *type = GL_UNSIGNED_BYTE; *d = out;
    return out;
}
// Runs `send` with the unpack state a repacked (tight) buffer needs: no row length or skips, alignment 1 for RGB rows;
// the guest's state comes back after.
void ShackGLUnpackTight(BOOL repacked, GLenum fmt, void (^send)(void)) {
    if (!repacked) { send(); return; }
    GLint align = 4, row = 0, skipP = 0, skipR = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glPixelStorei(GL_UNPACK_ALIGNMENT, fmt == GL_RGB ? 1 : 4); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0); glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    send();
    glPixelStorei(GL_UNPACK_ALIGNMENT, align); glPixelStorei(GL_UNPACK_ROW_LENGTH, row);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, skipP); glPixelStorei(GL_UNPACK_SKIP_ROWS, skipR);
}

// Texture allocations as desktop GL makes them, for ES 3 (ShackGL.m's glTexImage2D): 16-bit normalized formats ES does
// not have become 16-bit float (renderable through EXT_color_buffer_half_float; Batman's GL_RGBA16/GL_RG16 targets), and
// an empty allocation gets the format and type ES pairs with its internal format (Batman's sRGB scene color came as
// BGRA 8_8_8_8_REV, which ES refuses with a sized format: the texture stayed empty and its framebuffer incomplete).
// An upload with pixels keeps its format and type (ShackGL.m repacks those).
void ShackGLTexAlloc(GLint *internal, GLenum *fmt, GLenum *type, const void *data) {
    switch (*internal) {
    case 0x805B: *internal = GL_RGBA16F; break;   // GL_RGBA16
    case 0x8054: *internal = GL_RGB16F; break;    // GL_RGB16
    case 0x822C: *internal = GL_RG16F; break;     // GL_RG16
    case 0x822A: *internal = GL_R16F; break;      // GL_R16
    }
    if (data) return;
    static const struct { GLint internal; GLenum fmt, type; } es[] = {
        { GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE }, { GL_SRGB8_ALPHA8, GL_RGBA, GL_UNSIGNED_BYTE }, { GL_RGB8, GL_RGB, GL_UNSIGNED_BYTE },
        { GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT }, { GL_RGB16F, GL_RGB, GL_HALF_FLOAT }, { GL_RG16F, GL_RG, GL_HALF_FLOAT },
        { GL_R16F, GL_RED, GL_HALF_FLOAT }, { GL_RGBA32F, GL_RGBA, GL_FLOAT }, { GL_R32F, GL_RED, GL_FLOAT },
        { GL_RG32F, GL_RG, GL_FLOAT }, { GL_R8, GL_RED, GL_UNSIGNED_BYTE }, { GL_RG8, GL_RG, GL_UNSIGNED_BYTE },
        { GL_RGB10_A2, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV }, { GL_R11F_G11F_B10F, GL_RGB, GL_HALF_FLOAT },
        { GL_DEPTH24_STENCIL8, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8 }, { GL_DEPTH_COMPONENT24, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT },
        { GL_DEPTH_COMPONENT16, GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT }, { GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT },
    };
    for (size_t i = 0; i < sizeof es / sizeof *es; i++)
        if (es[i].internal == *internal) { *fmt = es[i].fmt; *type = es[i].type; return; }
}

static void *shack_glCreateProgramObjectARB(void) { return (void *)(uintptr_t)glCreateProgram(); }
static void shack_glAttachObjectARB(void *p, void *s) { shack_glAttachShader((GLuint)(uintptr_t)p, (GLuint)(uintptr_t)s); }
static void shack_glDetachObjectARB(void *p, void *s) { shack_glDetachShader((GLuint)(uintptr_t)p, (GLuint)(uintptr_t)s); }
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
             "GL_EXT_texture_compression_s3tc GL_EXT_texture_sRGB GL_ARB_texture_compression_rgtc GL_ARB_occlusion_query "
             "GL_ARB_occlusion_query2", es ? es : "");
    if (!es) return (const GLubyte *)s;   // ponytail: leaks this one uncached string per early call
    char *expected = NULL;
    if (!atomic_compare_exchange_strong(&all, &expected, s)) { free(s); s = expected; }
    return (const GLubyte *)s;
}

// GL 3 style queries (SDL_GL_ExtensionSupported on a "3.3" context reads these, not glGetString): the same extras.
static const char *const kExtra[] = { "GL_ARB_multitexture", "GL_ARB_shader_objects", "GL_ARB_vertex_shader",
    "GL_ARB_fragment_shader", "GL_ARB_shading_language_100", "GL_ARB_texture_non_power_of_two", "GL_ARB_vertex_buffer_object",
    "GL_EXT_framebuffer_object", "GL_ARB_framebuffer_object", "GL_EXT_blend_equation_separate", "GL_EXT_blend_func_separate",
    "GL_EXT_blend_minmax", "GL_EXT_texture_compression_s3tc", "GL_EXT_texture_sRGB", "GL_ARB_texture_compression_rgtc",
    "GL_ARB_occlusion_query", "GL_ARB_occlusion_query2" };
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
        {"glCompileShader", shack_glCompileShader}, {"glDrawArrays", shack_glDrawArrays}, {"glDrawElements", shack_glDrawElements}, {"glLinkProgram", shack_glLinkProgram}, {"glAttachShader", shack_glAttachShader}, {"glDetachShader", shack_glDetachShader},
        {"glVertexAttribPointer", shack_glVertexAttribPointer}, {"glVertexAttribIPointer", shack_glVertexAttribIPointer}, {"glDeleteBuffers", shack_glDeleteBuffers}, {"glEnableVertexAttribArray", shack_glEnableVertexAttribArray},
        {"glBeginQuery", shack_glBeginQuery}, {"glEndQuery", shack_glEndQuery}, {"glGetQueryiv", shack_glGetQueryiv},
        {"glGetQueryObjectiv", shack_glGetQueryObjectiv}, {"glTexParameterf", shack_glTexParameterf}, {"glTexParameterfv", shack_glTexParameterfv}, {"glColorMaski", shack_glColorMaski},
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
