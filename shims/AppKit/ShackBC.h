// Desktop S3TC/RGTC texture formats on iOS's GL ES (ShackGLTexture.m).
#pragma once
#include <stdint.h>

// What a compressed format becomes: `astc` is the ASTC 4x4 internal format BC1/BC3 blocks are re-encoded as (0 when the
// format is decoded to pixels of `internal`/`format`/`type` instead); bc is the block kind (1 BC1, 2 BC2, 3 BC3, 4 BC4,
// 5 BC5); rgba marks COMPRESSED_RGBA_S3TC_DXT1 (three-colour blocks carry transparent texels).
typedef struct { uint32_t internal, format, type, astc; int channels, bc, sign, rgba; } ShackBCDecoded;

int ShackBCFormat(uint32_t glFormat, ShackBCDecoded *out);
void *ShackBCDecode(const ShackBCDecoded *d, const uint8_t *src, int w, int h);
