// Mac check of the S3TC/RGTC decoder (shims/AppKit/ShackGLTexture.m):
// clang -fobjc-arc -DSHACK_BC_TEST shims/AppKit/ShackGLTexture.m shims/AppKit/ShackASTC.c host/probe/test_bc.m -framework Foundation -o /tmp/t && /tmp/t
#define GL_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <OpenGL/gl3.h>
#import <assert.h>

#include "../../shims/AppKit/ShackBC.h"

int main(void) {
    ShackBCDecoded d;
    // DXT1: c0 = red (0xF800) > c1 = blue (0x001F), indices 0,1,2,3 across the first row, then all 0.
    assert(ShackBCFormat(0x83F1, &d) && d.bc == 1 && d.channels == 4);
    uint8_t b1[8] = { 0x00, 0xF8, 0x1F, 0x00, 0xE4, 0, 0, 0 };
    uint8_t *p = ShackBCDecode(&d, b1, 4, 4);
    assert(p[0] == 255 && p[2] == 0 && p[3] == 255);                 // red
    assert(p[4] == 0 && p[6] == 255);                                // blue
    assert(p[8] == 170 && p[10] == 85);                              // 2/3 red
    assert(p[12] == 85 && p[14] == 170);                             // 1/3 red
    free(p);
    // DXT1 three-colour mode: c0 <= c1, index 3 is transparent black.
    uint8_t b1t[8] = { 0x1F, 0x00, 0x00, 0xF8, 0x03, 0, 0, 0 };
    p = ShackBCDecode(&d, b1t, 4, 4);
    assert(p[3] == 0 && p[0] == 0 && p[4 + 3] == 255);
    free(p);
    // DXT5 alpha: a0 = 255, a1 = 0, first texel index 1 (0), second index 0 (255).
    assert(ShackBCFormat(0x83F3, &d) && d.bc == 3);
    uint8_t b3[16] = { 255, 0, 0x01, 0, 0, 0, 0, 0, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0 };
    p = ShackBCDecode(&d, b3, 4, 4);
    assert(p[3] == 0 && p[7] == 255 && p[0] == 255);
    free(p);
    // DXT3 explicit 4-bit alpha, and a region smaller than a block (2x2).
    assert(ShackBCFormat(0x83F2, &d) && d.bc == 2);
    uint8_t b2[16] = { 0x5F, 0, 0, 0, 0, 0, 0, 0, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0 };
    p = ShackBCDecode(&d, b2, 2, 2);
    assert(p[3] == 255 && p[7] == 85);
    free(p);
    // RGTC2: two channels per pixel, red from the first block, green from the second.
    assert(ShackBCFormat(0x8DBD, &d) && d.channels == 2 && d.internal == GL_RG8);
    uint8_t b5[16] = { 200, 10, 0, 0, 0, 0, 0, 0, 50, 60, 0, 0, 0, 0, 0, 0 };
    p = ShackBCDecode(&d, b5, 4, 4);
    assert(p[0] == 200 && p[1] == 50 && p[30] == 200 && p[31] == 50);
    free(p);
    // Signed RGTC1: -127 end.
    assert(ShackBCFormat(0x8DBC, &d) && d.sign);
    uint8_t b4[8] = { 0x81, 0x7F, 0, 0, 0, 0, 0, 0 };
    p = ShackBCDecode(&d, b4, 4, 4);
    assert((int8_t)p[0] == -127);
    free(p);
    // sRGB DXT5 decodes to sRGB storage; BPTC and ASTC are not ours.
    assert(ShackBCFormat(0x8C4F, &d) && d.internal == GL_SRGB8_ALPHA8);
    assert(!ShackBCFormat(0x8E8C, NULL) && !ShackBCFormat(0x93B0, NULL));
    puts("bc ok");
}
