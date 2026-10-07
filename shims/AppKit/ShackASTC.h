// S3TC blocks to ASTC 4x4 LDR blocks (ShackASTC.c).
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// bc: one 8-byte BC1 block; rgbaVariant: COMPRESSED_RGBA_S3TC_DXT1 (transparent black in three-colour blocks).
void ShackASTCFromBC1(const uint8_t bc[8], int rgbaVariant, uint8_t out[16]);
// bc: one 16-byte BC3 block.
void ShackASTCFromBC3(const uint8_t bc[16], uint8_t out[16]);
// The five trits a packed trit byte stands for (test hook).
int ShackASTCTritsOf(int T, int t[5]);
#ifdef __cplusplus
}
#endif
