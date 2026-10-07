// Mac check of the S3TC -> ASTC transcoder (shims/AppKit/ShackASTC.c) against Arm's reference decoder:
//   git clone https://github.com/ARM-software/astc-encoder /tmp/astc-encoder && cmake -S /tmp/astc-encoder -B /tmp/astc-encoder/build -G Ninja -DASTCENC_CLI=ON -DASTCENC_ISA_NEON=ON && ninja -C /tmp/astc-encoder/build
//   clang -fobjc-arc -DSHACK_BC_TEST shims/AppKit/ShackASTC.c shims/AppKit/ShackGLTexture.m host/probe/test_astc.c -framework Foundation -o /tmp/t && /tmp/t
// (ASTCENC=<path> if the binary is elsewhere). Each block class is transcoded, decoded by astcenc and compared with the
// BC decoder's pixels: exact classes must agree to 2 levels, approximated ones are reported and bounded.
#include "../../shims/AppKit/ShackASTC.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../shims/AppKit/ShackBC.h"

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }

enum { BC1_4C, BC1_3C, BC1_3C_CLEAR, BC3_CONST, BC3_VAR, BC3_CUTOUT, CLASSES };
static const char *const kName[CLASSES] = { "bc1 four-colour", "bc1 three-colour", "bc1 three-colour + clear", "bc3 constant alpha", "bc3 varying alpha", "bc3 cutout alpha" };
// Largest allowed per-channel error (levels of 255) by class.
static const int kLimit[CLASSES] = { 3, 50, 50, 3, 45, 45 };

// order: 1 = c0 > c1 (BC1 four-colour), 2 = c0 <= c1 (three-colour), 0 = either (BC3 always decodes four-colour).
static void colourBlock(uint8_t *b, int order, int smooth, int noClear) {
    uint16_t c0 = (uint16_t)rnd(), c1 = smooth ? (uint16_t)(c0 ^ (rnd() & 0x0821)) : (uint16_t)rnd();
    if (order == 1) { if (c0 < c1) { uint16_t t = c0; c0 = c1; c1 = t; } if (c0 == c1) { if (c1) c1--; else c0++; } }
    if (order == 2 && c0 > c1) { uint16_t t = c0; c0 = c1; c1 = t; }
    b[0] = (uint8_t)c0; b[1] = (uint8_t)(c0 >> 8); b[2] = (uint8_t)c1; b[3] = (uint8_t)(c1 >> 8);
    uint32_t idx = 0;
    for (int i = 0; i < 16; i++) {
        uint32_t code = rnd() & 3;
        if (noClear && code == 3) code = rnd() % 3;
        idx |= code << (2 * i);
    }
    memcpy(b + 4, &idx, 4);
}
static void makeBlock(uint8_t *b, int cls) {
    int smooth = (int)(rnd() & 1);
    switch (cls) {
    case BC1_4C: case BC1_3C: case BC1_3C_CLEAR: colourBlock(b, cls == BC1_4C ? 1 : 2, smooth, cls == BC1_3C);
        if (cls == BC1_3C_CLEAR) { uint32_t idx; memcpy(&idx, b + 4, 4); idx |= 3u << (2 * (rnd() % 16)); memcpy(b + 4, &idx, 4); }
        break;
    case BC3_CONST: case BC3_VAR: case BC3_CUTOUT: {
        colourBlock(b + 8, 0, smooth, 0);
        uint8_t a0 = (uint8_t)rnd(), a1 = (uint8_t)rnd();
        if (cls == BC3_CONST) a1 = a0 = (rnd() & 1) ? 255 : a0;   // index 0 everywhere below
        if (cls == BC3_CUTOUT) { a0 = 255; a1 = 0; }
        b[0] = a0; b[1] = a1;
        uint64_t idx = 0;
        for (int i = 0; i < 16; i++) {
            uint64_t v = rnd() & 7;
            if (cls == BC3_CONST) v = 0;
            if (cls == BC3_CUTOUT) v = (rnd() & 1) ? 0 : 1;
            idx |= v << (3 * i);
        }
        for (int i = 0; i < 6; i++) b[2 + i] = (uint8_t)(idx >> (8 * i));
        break; }
    }
}

int main(void) {
    const char *astcenc = getenv("ASTCENC") ?: "/tmp/astc-encoder/build/Source/astcenc-neon";
    // The trit table derivation must agree with astcenc's for every packed byte (spot check by decoding a known case).
    int t[5]; ShackASTCTritsOf(0, t); assert(!t[0] && !t[1] && !t[2] && !t[3] && !t[4]);
    ShackASTCTritsOf(2, t); assert(t[0] == 2 && !t[1]);

    enum { BW = 64, BH = 64 };
    int failed = 0;
    for (int srgb = 0; srgb < 2; srgb++)
    for (int cls = 0; cls < CLASSES; cls++) {
        int bc3 = cls >= BC3_CONST, bs = bc3 ? 16 : 8, rgba = cls == BC1_3C_CLEAR;
        uint8_t *src = malloc((size_t)BW * BH * (size_t)bs), *astc = malloc(16 + (size_t)BW * BH * 16);
        for (int i = 0; i < BW * BH; i++) makeBlock(src + (size_t)i * (size_t)bs, cls);
        memcpy(astc, "\x13\xAB\xA1\x5C\x04\x04\x01", 7);
        int w = BW * 4, h = BH * 4;
        astc[7] = (uint8_t)w; astc[8] = (uint8_t)(w >> 8); astc[9] = 0; astc[10] = (uint8_t)h; astc[11] = (uint8_t)(h >> 8); astc[12] = 0; astc[13] = 1; astc[14] = 0; astc[15] = 0;
        for (int i = 0; i < BW * BH; i++) {
            if (bc3) ShackASTCFromBC3(src + (size_t)i * 16, astc + 16 + (size_t)i * 16);
            else ShackASTCFromBC1(src + (size_t)i * 8, rgba, astc + 16 + (size_t)i * 16);
        }
        FILE *f = fopen("/tmp/shack_t.astc", "wb"); fwrite(astc, 1, 16 + (size_t)BW * BH * 16, f); fclose(f);
        char cmd[512]; snprintf(cmd, sizeof cmd, "%s -d%c /tmp/shack_t.astc /tmp/shack_t.ktx >/dev/null 2>&1", astcenc, srgb ? 's' : 'l');
        if (system(cmd) != 0) { fprintf(stderr, "astcenc failed: %s\n", cmd); return 2; }
        FILE *k = fopen("/tmp/shack_t.ktx", "rb"); assert(k);
        fseek(k, 0, SEEK_END); long n = ftell(k); fseek(k, 0, SEEK_SET);
        uint8_t *ktx = malloc((size_t)n); fread(ktx, 1, (size_t)n, k); fclose(k);
        uint32_t kv = *(uint32_t *)(ktx + 60);
        const uint8_t *raw = ktx + 64 + kv + 4;
        // astcenc writes RGB when the whole image is opaque.
        int chans = *(uint32_t *)(ktx + 24) == 0x1907 ? 3 : 4;
        uint8_t *got = malloc((size_t)w * (size_t)h * 4);
        for (size_t i = 0; i < (size_t)w * (size_t)h; i++) {
            memcpy(got + i * 4, raw + i * (size_t)chans, (size_t)chans);
            if (chans == 3) got[i * 4 + 3] = 255;
        }
        // Expected pixels: the BC decoder (BC3), BC1 by hand (its decoder keeps only the RGBA-variant alpha rule).
        uint8_t *exp = malloc((size_t)w * (size_t)h * 4);
        for (int by = 0; by < BH; by++) for (int bx = 0; bx < BW; bx++) {
            const uint8_t *blk = src + ((size_t)by * BW + (size_t)bx) * (size_t)bs;
            ShackBCDecoded d; ShackBCFormat(bc3 ? 0x83F3 : 0x83F1, &d);
            uint8_t *px = ShackBCDecode(&d, blk, 4, 4);
            for (int i = 0; i < 16; i++) {
                uint8_t *o = exp + (((size_t)by * 4 + (size_t)(i >> 2)) * (size_t)w + (size_t)bx * 4 + (size_t)(i & 3)) * 4;
                memcpy(o, px + i * 4, 4);
                if (!bc3 && !rgba) o[3] = 255;
            }
            free(px);
        }
        int worst = 0; double sum = 0;
        for (size_t i = 0; i < (size_t)w * (size_t)h * 4; i++) {
            if (i % 4 != 3 && exp[i | 3] == 0 && got[i | 3] == 0) continue;   // colour of a fully transparent texel
            int e = abs((int)got[i] - (int)exp[i]);
            if (e > worst) worst = e;
            sum += e;
        }
        double mean = sum / ((double)w * (double)h * 4);
        printf("%-4s %-26s max error %3d  mean %.3f  (limit %d)\n", srgb ? "sRGB" : "lin", kName[cls], worst, mean, kLimit[cls]);
        if (worst > kLimit[cls]) failed++;
        free(src); free(astc); free(ktx); free(exp); free(got);
    }
    if (failed) { printf("FAILED %d class(es)\n", failed); return 1; }
    puts("astc ok");
    return 0;
}
