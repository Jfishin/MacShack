// Desktop compressed textures on OpenGL ES: iOS's GL has ASTC and PVRTC but none of S3TC/RGTC, which desktop GL
// games upload as a matter of course (Unity's desktop build: DXT1/DXT5 everywhere; GPU support is assumed, so the
// textures stayed black). ShackGL.m sends storage requests and compressed uploads of those formats here: storage is
// allocated in the decoded format, and each upload is decoded on the CPU and uploaded as plain pixels.
// ponytail: BC1-BC5 only; BC7/BC6H (BPTC) are logged once. Unity decompresses BC6H itself when told it is missing.
#define GLES_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#ifdef SHACK_BC_TEST
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/gl3.h>
#else
#import <OpenGLES/ES3/gl.h>
#endif
#import <stdatomic.h>
#import <dispatch/dispatch.h>
#import "ShackBC.h"
#import "ShackASTC.h"

#define ASTC_4x4 0x93B0        // COMPRESSED_RGBA_ASTC_4x4_KHR
#define ASTC_4x4_SRGB 0x93D0   // COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR

// S3TC (EXT_texture_compression_s3tc, EXT_texture_sRGB) and RGTC formats and what they decode to.
int ShackBCFormat(uint32_t f, ShackBCDecoded *out) {
    ShackBCDecoded d = { GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 0, 4, 0, 0, 0 };
    switch (f) {
    case 0x83F0: case 0x83F1: d.bc = 1; d.astc = ASTC_4x4; d.rgba = f == 0x83F1; break;                  // DXT1 RGB / RGBA
    case 0x83F2: d.bc = 2; break;                                                                        // DXT3
    case 0x83F3: d.bc = 3; d.astc = ASTC_4x4; break;                                                     // DXT5
    case 0x8C4C: case 0x8C4D: d.bc = 1; d.internal = GL_SRGB8_ALPHA8; d.astc = ASTC_4x4_SRGB; d.rgba = f == 0x8C4D; break;
    case 0x8C4E: d.bc = 2; d.internal = GL_SRGB8_ALPHA8; break;                                          // sRGB DXT3
    case 0x8C4F: d.bc = 3; d.internal = GL_SRGB8_ALPHA8; d.astc = ASTC_4x4_SRGB; break;                  // sRGB DXT5
    case 0x8DBB: d = (ShackBCDecoded){ GL_R8, GL_RED, GL_UNSIGNED_BYTE, 0, 1, 4, 0, 0 }; break;          // RGTC1
    case 0x8DBC: d = (ShackBCDecoded){ GL_R8_SNORM, GL_RED, GL_BYTE, 0, 1, 4, 1, 0 }; break;             // signed RGTC1
    case 0x8DBD: d = (ShackBCDecoded){ GL_RG8, GL_RG, GL_UNSIGNED_BYTE, 0, 2, 5, 0, 0 }; break;          // RGTC2
    case 0x8DBE: d = (ShackBCDecoded){ GL_RG8_SNORM, GL_RG, GL_BYTE, 0, 2, 5, 1, 0 }; break;             // signed RGTC2
    case 0x8E8C: case 0x8E8D: case 0x8E8E: case 0x8E8F: {                        // BPTC (BC7, BC6H)
        static atomic_bool said;
        if (!atomic_exchange(&said, true)) NSLog(@"[ShackGL] BPTC (BC6H/BC7) texture 0x%x: not decoded, it stays black", f);
        return 0;
    }
    default: return 0;
    }
    if (out) *out = d;
    return 1;
}

static void color565(uint16_t c, uint8_t out[3]) {
    out[0] = (uint8_t)(((c >> 11) & 31) * 255 / 31);
    out[1] = (uint8_t)(((c >> 5) & 63) * 255 / 63);
    out[2] = (uint8_t)((c & 31) * 255 / 31);
}
// A BC1 colour block into a 4x4 RGBA tile; `four` forces the four-colour mode BC2/BC3 always use.
static void bc1(const uint8_t *b, uint8_t tile[16][4], int four) {
    uint16_t c0 = (uint16_t)(b[0] | b[1] << 8), c1 = (uint16_t)(b[2] | b[3] << 8);
    uint8_t p[4][4];
    color565(c0, p[0]); color565(c1, p[1]); p[0][3] = p[1][3] = 255;
    if (four || c0 > c1) {
        for (int k = 0; k < 3; k++) { p[2][k] = (uint8_t)((2 * p[0][k] + p[1][k]) / 3); p[3][k] = (uint8_t)((p[0][k] + 2 * p[1][k]) / 3); }
        p[2][3] = p[3][3] = 255;
    } else {
        for (int k = 0; k < 3; k++) { p[2][k] = (uint8_t)((p[0][k] + p[1][k]) / 2); p[3][k] = 0; }
        p[2][3] = 255; p[3][3] = 0;   // transparent black
    }
    uint32_t idx = (uint32_t)(b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24);
    for (int i = 0; i < 16; i++) memcpy(tile[i], p[(idx >> (2 * i)) & 3], 4);
}
// A BC4 block (BC3's alpha, RGTC's channels) into 16 values; signed blocks give int8 values in uint8 storage.
static void bc4(const uint8_t *b, uint8_t out[16], int sign) {
    int a0 = sign ? (int8_t)b[0] : b[0], a1 = sign ? (int8_t)b[1] : b[1], lo = sign ? -127 : 0, hi = sign ? 127 : 255;
    if (sign) { if (a0 < -127) a0 = -127; if (a1 < -127) a1 = -127; }
    int v[8] = { a0, a1 };
    if (a0 > a1) for (int i = 1; i < 7; i++) v[i + 1] = ((7 - i) * a0 + i * a1) / 7;
    else { for (int i = 1; i < 5; i++) v[i + 1] = ((5 - i) * a0 + i * a1) / 5; v[6] = lo; v[7] = hi; }
    uint64_t idx = 0;
    for (int i = 0; i < 6; i++) idx |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) out[i] = (uint8_t)(int8_t)v[(idx >> (3 * i)) & 7];
}

// What the layer has converted, logged every 256 MB of output: decoded pixels are 4-8x the BC size, ASTC is 1-2x.
static void countConverted(int astc, size_t in, size_t out) {
    static _Atomic size_t decodedIn, decodedOut, astcIn, astcOut, total;
    if (astc) { atomic_fetch_add(&astcIn, in); atomic_fetch_add(&astcOut, out); } else { atomic_fetch_add(&decodedIn, in); atomic_fetch_add(&decodedOut, out); }
    size_t before = atomic_fetch_add(&total, out);
    if ((before >> 28) != ((before + out) >> 28))
        NSLog(@"[ShackGL] textures converted so far: ASTC %zu MB (from %zu MB of BC), RGBA8/R8/RG8 %zu MB (from %zu MB)",
              atomic_load(&astcOut) >> 20, atomic_load(&astcIn) >> 20, atomic_load(&decodedOut) >> 20, atomic_load(&decodedIn) >> 20);
}

// Decodes a w x h region of blocks into tightly packed pixels of d->channels bytes each; returns malloc'd memory.
void *ShackBCDecode(const ShackBCDecoded *d, const uint8_t *src, int w, int h) {
    int bw = (w + 3) / 4, bh = (h + 3) / 4, bs = d->bc == 1 || d->bc == 4 ? 8 : 16, ch = d->channels;
    uint8_t *px = malloc((size_t)w * (size_t)h * (size_t)ch);
    if (!px) return NULL;
    countConverted(0, (size_t)((w + 3) / 4) * (size_t)((h + 3) / 4) * (size_t)bs, (size_t)w * (size_t)h * (size_t)ch);
    for (int by = 0; by < bh; by++)
        for (int bx = 0; bx < bw; bx++) {
            const uint8_t *b = src + ((size_t)by * (size_t)bw + (size_t)bx) * (size_t)bs;
            uint8_t tile[16][4], a[16], g[16];
            switch (d->bc) {
            case 1: bc1(b, tile, 0); break;
            case 2: bc1(b + 8, tile, 1); for (int i = 0; i < 16; i++) tile[i][3] = (uint8_t)(((b[i / 2] >> (4 * (i & 1))) & 15) * 17); break;
            case 3: bc1(b + 8, tile, 1); bc4(b, a, 0); for (int i = 0; i < 16; i++) tile[i][3] = a[i]; break;
            case 4: bc4(b, a, d->sign); for (int i = 0; i < 16; i++) tile[i][0] = a[i]; break;
            default: bc4(b, a, d->sign); bc4(b + 8, g, d->sign); for (int i = 0; i < 16; i++) { tile[i][0] = a[i]; tile[i][1] = g[i]; } break;
            }
            for (int i = 0; i < 16; i++) {
                int x = bx * 4 + (i & 3), y = by * 4 + (i >> 2);
                if (x < w && y < h) memcpy(px + ((size_t)y * (size_t)w + (size_t)x) * (size_t)ch, tile[i], (size_t)ch);
            }
        }
    return px;
}

#ifndef SHACK_BC_TEST
// Compressed data may come from a pixel unpack buffer (the pointer is then an offset into it).
static const uint8_t *unpackSource(const void *data, GLsizei size, BOOL *mapped) {
    GLint pbo = 0; glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    *mapped = pbo != 0;
    return pbo ? glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, (GLintptr)data, size, GL_MAP_READ_BIT) : data;
}
// Uploads converted data with no unpack buffer bound and the unpack state a tight buffer needs, then restores the game's.
static void upload(void (^send)(void)) {
    GLint align = 4, row = 0, skipP = 0, skipR = 0, pbo = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &align); glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row);
    glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skipP); glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skipR);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
    if (pbo) glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0); glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    send();
    glPixelStorei(GL_UNPACK_ALIGNMENT, align); glPixelStorei(GL_UNPACK_ROW_LENGTH, row);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, skipP); glPixelStorei(GL_UNPACK_SKIP_ROWS, skipR);
    if (pbo) glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)pbo);
}

static size_t blocksOf(int w, int h) { return (size_t)((w + 3) / 4) * (size_t)((h + 3) / 4); }
static size_t blockBytes(const ShackBCDecoded *d) { return d->bc == 1 || d->bc == 4 ? 8 : 16; }

// `blocks` BC1/BC3 blocks re-encoded as ASTC 4x4 (16 bytes each); large uploads are split across cores. malloc'd.
static uint8_t *transcode(const ShackBCDecoded *d, const uint8_t *src, size_t blocks) {
    uint8_t *out = malloc(blocks * 16);
    if (!out) return NULL;
    size_t bs = blockBytes(d);
    const size_t chunk = 4096, chunks = (blocks + chunk - 1) / chunk;
    void (^run)(size_t) = ^(size_t c) {
        size_t lo = c * chunk, hi = lo + chunk < blocks ? lo + chunk : blocks;
        if (d->bc == 1) for (size_t i = lo; i < hi; i++) ShackASTCFromBC1(src + i * bs, d->rgba, out + i * 16);
        else for (size_t i = lo; i < hi; i++) ShackASTCFromBC3(src + i * bs, out + i * 16);
    };
    if (chunks > 2) dispatch_apply(chunks, DISPATCH_APPLY_AUTO, run);
    else for (size_t c = 0; c < chunks; c++) run(c);
    countConverted(1, blocks * bs, blocks * 16);
    return out;
}

// Returns 1 when it handled the call (a BC format), 0 to pass it through unchanged.
int ShackBCCompressedTexImage2D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLsizei size, const void *data) {
    ShackBCDecoded d;
    if (!ShackBCFormat(f, &d)) return 0;
    BOOL mapped = NO; const uint8_t *src = NULL;
    if (d.astc) {
        size_t blocks = blocksOf(w, h);
        GLint pbo = 0; glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        if (!data && !pbo) { upload(^{ glCompressedTexImage2D(t, l, d.astc, w, h, 0, (GLsizei)(blocks * 16), NULL); }); return 1; }
        src = unpackSource(data, size, &mapped);
        uint8_t *out = src ? transcode(&d, src, blocks) : NULL;
        if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        upload(^{ glCompressedTexImage2D(t, l, d.astc, w, h, 0, (GLsizei)(blocks * 16), out); });
        free(out);
        return 1;
    }
    src = unpackSource(data, size, &mapped);
    void *px = src ? ShackBCDecode(&d, src, w, h) : NULL;
    if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    upload(^{ glTexImage2D(t, l, (GLint)d.internal, w, h, 0, d.format, d.type, px); });
    free(px);
    return 1;
}
int ShackBCCompressedTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLsizei size, const void *data) {
    ShackBCDecoded d;
    if (!ShackBCFormat(f, &d)) return 0;
    BOOL mapped; const uint8_t *src = unpackSource(data, size, &mapped);
    if (d.astc) {
        size_t blocks = blocksOf(w, h);
        uint8_t *out = src ? transcode(&d, src, blocks) : NULL;
        if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        if (out) upload(^{ glCompressedTexSubImage2D(t, l, x, y, w, h, d.astc, (GLsizei)(blocks * 16), out); });
        free(out);
        return 1;
    }
    void *px = src ? ShackBCDecode(&d, src, w, h) : NULL;
    if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    if (px) upload(^{ glTexSubImage2D(t, l, x, y, w, h, d.format, d.type, px); });
    free(px);
    return 1;
}
int ShackBCCompressedTexImage3D(GLenum t, GLint l, GLenum f, GLsizei w, GLsizei h, GLsizei depth, GLsizei size, const void *data) {
    ShackBCDecoded d;
    if (!ShackBCFormat(f, &d)) return 0;
    size_t slice = blocksOf(w, h) * blockBytes(&d);
    if (d.astc) {
        size_t blocks = blocksOf(w, h) * (size_t)depth;
        GLint pbo = 0; glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        if (!data && !pbo) { upload(^{ glCompressedTexImage3D(t, l, d.astc, w, h, depth, 0, (GLsizei)(blocks * 16), NULL); }); return 1; }
        BOOL mapped; const uint8_t *src = unpackSource(data, size, &mapped);
        uint8_t *out = src ? transcode(&d, src, blocks) : NULL;
        if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        upload(^{ glCompressedTexImage3D(t, l, d.astc, w, h, depth, 0, (GLsizei)(blocks * 16), out); });
        free(out);
        return 1;
    }
    upload(^{ glTexImage3D(t, l, (GLint)d.internal, w, h, depth, 0, d.format, d.type, NULL); });
    if (!data && !size) return 1;
    BOOL mapped; const uint8_t *src = unpackSource(data, size, &mapped);
    for (GLsizei z = 0; src && z < depth; z++) {
        void *px = ShackBCDecode(&d, src + slice * (size_t)z, w, h);
        if (px) upload(^{ glTexSubImage3D(t, l, 0, 0, z, w, h, 1, d.format, d.type, px); });
        free(px);
    }
    if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    return 1;
}
int ShackBCCompressedTexSubImage3D(GLenum t, GLint l, GLint x, GLint y, GLint z0, GLsizei w, GLsizei h, GLsizei depth, GLenum f, GLsizei size, const void *data) {
    ShackBCDecoded d;
    if (!ShackBCFormat(f, &d)) return 0;
    size_t slice = blocksOf(w, h) * blockBytes(&d);
    BOOL mapped; const uint8_t *src = unpackSource(data, size, &mapped);
    if (d.astc) {
        size_t blocks = blocksOf(w, h) * (size_t)depth;
        uint8_t *out = src ? transcode(&d, src, blocks) : NULL;
        if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
        if (out) upload(^{ glCompressedTexSubImage3D(t, l, x, y, z0, w, h, depth, d.astc, (GLsizei)(blocks * 16), out); });
        free(out);
        return 1;
    }
    for (GLsizei z = 0; src && z < depth; z++) {
        void *px = ShackBCDecode(&d, src + slice * (size_t)z, w, h);
        if (px) upload(^{ glTexSubImage3D(t, l, x, y, z0 + z, w, h, 1, d.format, d.type, px); });
        free(px);
    }
    if (mapped) glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER);
    return 1;
}
// Storage for a BC format is allocated as what it becomes (ASTC, or decoded pixels); the internal format to use, or `f` unchanged.
GLenum ShackBCStorageFormat(GLenum f) {
    ShackBCDecoded d;
    return ShackBCFormat(f, &d) ? (d.astc ? d.astc : d.internal) : f;
}
#endif
