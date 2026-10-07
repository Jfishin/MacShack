// S3TC (BC1/BC3) blocks re-encoded as ASTC 4x4 LDR blocks without going through pixels. iOS has ASTC and no S3TC;
// decoding to RGBA8 costs 4-8x the memory of the source, while the two formats share the 4x4 block grid, so a BC block
// becomes one ASTC block: 1 byte per pixel, 2x BC1 and equal to BC3.
//
// Block types (single partition, 2-bit weights; ASTC spec section C.2, checked against Arm's astcenc in test_astc.py):
//   T1  CEM 8, RGB, 8-bit endpoints: BC1's four-colour mode exactly (0, 1/3, 2/3, 1 are ASTC's 2-bit weights 0,21,43,64).
//   T2  CEM 12, RGBA, 8-bit endpoints, one weight set: BC3 blocks whose alpha is constant.
//   T3  CEM 12 dual plane, alpha on the second plane, endpoints 48 levels (trit + 4 bits, the most 45 bits hold):
//       BC3 with varying alpha (alpha becomes 4 levels between the block's min and max) and BC1's transparent texels.
// Approximations: BC1 three-colour blocks put the midpoint on 1/3; alpha keeps 4 levels per block instead of BC3's 8.
#include "ShackASTC.h"
#include <pthread.h>
#include <string.h>

typedef unsigned __int128 u128;

// Unquantized value of each symbol ((trit << 4) | 4 bits) in the 48-level endpoint range (ASTC quant table).
static const uint8_t kQ48[48] = {
      0, 255,  16, 239,  32, 223,  48, 207,  65, 190,  81, 174,  97, 158, 113, 142,
      5, 250,  21, 234,  38, 217,  54, 201,  70, 185,  86, 169, 103, 152, 119, 136,
     11, 244,  27, 228,  43, 212,  59, 196,  76, 179,  92, 163, 108, 147, 124, 131 };
static uint8_t gQ48Symbol[256];            // nearest symbol for an 8-bit value
static uint8_t gTritCode[3][3][3][3][3];   // packed trit byte for trits [t4][t3][t2][t1][t0]
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

// The five trits a packed byte stands for (ASTC spec, integer sequence encoding).
static void tritsOf(int T, int t[5]) {
    int C, t3, t4;
    if (((T >> 2) & 7) == 7) { C = (((T >> 5) & 7) << 2) | (T & 3); t4 = 2; t3 = 2; }
    else {
        C = T & 31;
        if (((T >> 5) & 3) == 3) { t4 = 2; t3 = (T >> 7) & 1; }
        else { t4 = (T >> 7) & 1; t3 = (T >> 5) & 3; }
    }
    if ((C & 3) == 3) { t[2] = 2; t[1] = (C >> 4) & 1; t[0] = (((C >> 3) & 1) << 1) | (((C >> 2) & 1) & ~((C >> 3) & 1)); }
    else if (((C >> 2) & 3) == 3) { t[2] = 2; t[1] = 2; t[0] = C & 3; }
    else { t[2] = (C >> 4) & 1; t[1] = (C >> 2) & 3; t[0] = C & 3; }
    t[3] = t3; t[4] = t4;
}
int ShackASTCTritsOf(int T, int t[5]) { tritsOf(T, t); return 0; }   // the test compares this with astcenc's table

static void init(void) {
    for (int T = 255; T >= 0; T--) {
        int t[5]; tritsOf(T, t);
        gTritCode[t[4]][t[3]][t[2]][t[1]][t[0]] = (uint8_t)T;
    }
    for (int v = 0; v < 256; v++) {
        int best = 0, err = 1000;
        for (int s = 0; s < 48; s++) { int e = v > kQ48[s] ? v - kQ48[s] : kQ48[s] - v; if (e < err) { err = e; best = s; } }
        gQ48Symbol[v] = (uint8_t)best;
    }
}

// Eight 48-level values (trit + 4 bits each) as one 45-bit integer sequence.
static uint64_t iseQ48x8(const uint8_t s[8]) {
    uint64_t out = 0; int pos = 0;
    #define PUT(v, n) do { out |= (uint64_t)((v) & ((1 << (n)) - 1)) << pos; pos += (n); } while (0)
    int t[8], m[8];
    for (int i = 0; i < 8; i++) { t[i] = s[i] >> 4; m[i] = s[i] & 15; }
    int T = gTritCode[t[4]][t[3]][t[2]][t[1]][t[0]];
    PUT(m[0], 4); PUT(T & 3, 2); PUT(m[1], 4); PUT((T >> 2) & 3, 2); PUT(m[2], 4); PUT((T >> 4) & 1, 1);
    PUT(m[3], 4); PUT((T >> 5) & 3, 2); PUT(m[4], 4); PUT((T >> 7) & 1, 1);
    T = gTritCode[0][0][t[7]][t[6]][t[5]];
    PUT(m[5], 4); PUT(T & 3, 2); PUT(m[6], 4); PUT((T >> 2) & 3, 2); PUT(m[7], 4); PUT((T >> 4) & 1, 1);
    #undef PUT
    return out;
}

static void store(u128 b, uint8_t out[16]) { memcpy(out, &b, 16); }   // little-endian, as ASTC's bit numbering

static uint32_t reverse32(uint32_t v) { return __builtin_bitreverse32(v); }
static uint64_t reverse64(uint64_t v) { return __builtin_bitreverse64(v); }

static void expand565(uint16_t c, int rgb[3]) {
    int r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
    rgb[0] = (r << 3) | (r >> 2); rgb[1] = (g << 2) | (g >> 4); rgb[2] = (b << 3) | (b >> 2);
}

// One weight set (16 x 2 bits) placed at the top of the block, bit-reversed as ASTC stores weights.
static u128 topWeights32(uint32_t w) { return (u128)reverse32(w) << 96; }

// T1/T2: single plane, 2-bit weights (block mode 0x42), 8-bit endpoints from bit 17.
static void singlePlane(int cem, const int e0[4], const int e1[4], uint32_t weights, uint8_t out[16]) {
    u128 b = 0x42 | ((u128)cem << 13);
    int n = cem == 8 ? 3 : 4;
    for (int i = 0; i < 3; i++) { b |= (u128)e0[i] << (17 + 16 * i); b |= (u128)e1[i] << (25 + 16 * i); }
    if (n == 4) { b |= (u128)e0[3] << 65; b |= (u128)e1[3] << 73; }
    store(b | topWeights32(weights), out);
}

// T3: dual plane, alpha on plane two (block mode 0x442, CEM 12). Weights alternate colour, alpha per texel.
static void dualPlane(const int e0[4], const int e1[4], const int wc[16], const int wa[16], uint8_t out[16]) {
    uint8_t s[8] = { gQ48Symbol[e0[0]], gQ48Symbol[e1[0]], gQ48Symbol[e0[1]], gQ48Symbol[e1[1]],
                     gQ48Symbol[e0[2]], gQ48Symbol[e1[2]], gQ48Symbol[e0[3]], gQ48Symbol[e1[3]] };
    uint64_t w = 0;
    for (int i = 0; i < 16; i++) w |= (uint64_t)wc[i] << (4 * i) | (uint64_t)wa[i] << (4 * i + 2);
    u128 b = 0x442 | ((u128)12 << 13) | ((u128)iseQ48x8(s) << 17) | ((u128)3 << 62) | ((u128)reverse64(w) << 64);
    store(b, out);
}

// Colour endpoints for the 2-bit weight set: blue contraction (which ASTC applies when the first endpoint's channel sum
// is larger) is avoided by swapping the endpoints and reversing the weights (w -> 3 - w).
static int orderEndpoints(int e0[4], int e1[4]) {
    if (e0[0] + e0[1] + e0[2] <= e1[0] + e1[1] + e1[2]) return 0;
    for (int i = 0; i < 3; i++) { int t = e0[i]; e0[i] = e1[i]; e1[i] = t; }
    return 1;
}
static int q48(int v) { return kQ48[gQ48Symbol[v]]; }

// BC1 index (0 c0, 1 c1, 2 two-thirds c0, 3 one-third c0) to ASTC weight index (0 e0, 1 a third, 2 two thirds, 3 e1).
static const uint8_t kIndexToWeight[4] = { 0, 3, 1, 2 };

void ShackASTCFromBC1(const uint8_t bc[8], int rgbaVariant, uint8_t out[16]) {
    pthread_once(&gOnce, init);
    uint16_t c0 = (uint16_t)(bc[0] | bc[1] << 8), c1 = (uint16_t)(bc[2] | bc[3] << 8);
    uint32_t idx = (uint32_t)bc[4] | (uint32_t)bc[5] << 8 | (uint32_t)bc[6] << 16 | (uint32_t)bc[7] << 24;
    int e0[4] = { 0, 0, 0, 255 }, e1[4] = { 0, 0, 0, 255 };
    expand565(c0, e0); expand565(c1, e1);
    int threeColour = c0 <= c1, clear = 0;   // transparent-black texels of the three-colour mode
    uint32_t used = 0;                       // which of the four codes appear
    for (int i = 0; i < 16; i++) used |= 1u << ((idx >> (2 * i)) & 3);
    if (threeColour && rgbaVariant && (used & 8)) clear = 1;

    if (!clear) {
        // Weights are worked out against the endpoints as BC1 has them (0 = c0, 3 = c1) and reversed if they get swapped.
        // Three-colour blocks: the midpoint takes 1/3; an opaque black texel takes the darker endpoint.
        int dark = e0[0] + e0[1] + e0[2] <= e1[0] + e1[1] + e1[2] ? 0 : 3;
        int swapped = orderEndpoints(e0, e1);
        uint32_t w = 0;
        for (int i = 0; i < 16; i++) {
            int code = (int)((idx >> (2 * i)) & 3);
            int wi = !threeColour ? kIndexToWeight[code] : code == 0 ? 0 : code == 1 ? 3 : code == 2 ? 1 : dark;
            w |= (uint32_t)(swapped ? 3 - wi : wi) << (2 * i);
        }
        singlePlane(8, e0, e1, w, out);
        return;
    }
    // Three-colour block with transparent texels: alpha rides on the second plane (0 or 255).
    int wc[16], wa[16];
    e0[3] = 0; e1[3] = 255;
    for (int k = 0; k < 3; k++) { e0[k] = q48(e0[k]); e1[k] = q48(e1[k]); }
    int swapped = orderEndpoints(e0, e1);
    for (int i = 0; i < 16; i++) {
        int code = (int)((idx >> (2 * i)) & 3);
        int wi = code == 0 ? 0 : code == 1 ? 3 : code == 2 ? 1 : 0;
        wc[i] = swapped ? 3 - wi : wi;
        wa[i] = code == 3 ? 0 : 3;
    }
    dualPlane(e0, e1, wc, wa, out);
}

// BC3 alpha block to 16 values (the same interpolation as BC4).
static void alphaValues(const uint8_t *b, uint8_t a[16]) {
    int a0 = b[0], a1 = b[1], v[8] = { a0, a1 };
    if (a0 > a1) for (int i = 1; i < 7; i++) v[i + 1] = ((7 - i) * a0 + i * a1) / 7;
    else { for (int i = 1; i < 5; i++) v[i + 1] = ((5 - i) * a0 + i * a1) / 5; v[6] = 0; v[7] = 255; }
    uint64_t idx = 0;
    for (int i = 0; i < 6; i++) idx |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) a[i] = (uint8_t)v[(idx >> (3 * i)) & 7];
}

void ShackASTCFromBC3(const uint8_t bc[16], uint8_t out[16]) {
    pthread_once(&gOnce, init);
    uint8_t a[16];
    alphaValues(bc, a);
    int lo = 255, hi = 0;
    for (int i = 0; i < 16; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i]; }
    const uint8_t *cb = bc + 8;
    uint16_t c0 = (uint16_t)(cb[0] | cb[1] << 8), c1 = (uint16_t)(cb[2] | cb[3] << 8);
    uint32_t idx = (uint32_t)cb[4] | (uint32_t)cb[5] << 8 | (uint32_t)cb[6] << 16 | (uint32_t)cb[7] << 24;
    int e0[4] = { 0, 0, 0, 0 }, e1[4] = { 0, 0, 0, 0 };
    expand565(c0, e0); expand565(c1, e1);
    if (lo == hi) {   // constant alpha (255 for most opaque textures): one weight set, exact
        e0[3] = e1[3] = lo;
        int swapped = orderEndpoints(e0, e1);
        uint32_t w = 0;
        for (int i = 0; i < 16; i++) {
            int wi = kIndexToWeight[(idx >> (2 * i)) & 3];   // BC2/BC3 colour blocks are always four-colour
            w |= (uint32_t)(swapped ? 3 - wi : wi) << (2 * i);
        }
        singlePlane(lo == 255 ? 8 : 12, e0, e1, w, out);
        return;
    }
    e0[3] = lo; e1[3] = hi;
    for (int k = 0; k < 3; k++) { e0[k] = q48(e0[k]); e1[k] = q48(e1[k]); }
    e0[3] = q48(lo); e1[3] = q48(hi);
    int swapped = orderEndpoints(e0, e1);
    static const int kW[4] = { 0, 21, 43, 64 };
    int wc[16], wa[16];
    for (int i = 0; i < 16; i++) {
        int wi = kIndexToWeight[(idx >> (2 * i)) & 3];
        wc[i] = swapped ? 3 - wi : wi;
        int best = 0, err = 1 << 20;
        for (int j = 0; j < 4; j++) {
            int v = (e0[3] * (64 - kW[j]) + e1[3] * kW[j] + 32) >> 6, d = v > a[i] ? v - a[i] : a[i] - v;
            if (d < err) { err = d; best = j; }
        }
        wa[i] = best;
    }
    dualPlane(e0, e1, wc, wa, out);
}
