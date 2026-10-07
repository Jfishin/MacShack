#ifndef SHACK_DISPLAY_H
#define SHACK_DISPLAY_H
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>

// An explicit guest desktop, independent of the phone's UIKit screen. Reject partial,
// signed, floating-point and oversized values; invalid/missing input keeps normal metrics.
static inline bool ShackParseDisplaySize(const char *text, CGSize *size) {
    if (!text) return false;
    unsigned dimensions[2] = {0, 0};
    for (int i = 0; i < 2; i++) {
        unsigned digits = 0;
        if (*text < '0' || *text > '9') return false;
        do {
            if (++digits > 4) return false;
            dimensions[i] = dimensions[i] * 10 + (unsigned)(*text++ - '0');
            if (dimensions[i] > 8192) return false;
        } while (*text >= '0' && *text <= '9');
        if (dimensions[i] < 64) return false;
        if (i == 0) { if (*text++ != 'x') return false; }
        else if (*text) return false;
    }
    if (size) *size = CGSizeMake(dimensions[0], dimensions[1]);
    return true;
}

static inline bool ShackVirtualDisplaySize(CGSize *size) {
    return ShackParseDisplaySize(getenv("SHACK_DISPLAY_SIZE"), size);
}

static inline CGRect ShackDisplayCanvasRect(CGSize canvas, CGRect bounds) {
    if (canvas.width <= 0 || canvas.height <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0) return CGRectZero;
    CGFloat scale = fmin(bounds.size.width / canvas.width, bounds.size.height / canvas.height);
    CGSize fitted = CGSizeMake(canvas.width * scale, canvas.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - fitted.width / 2, CGRectGetMidY(bounds) - fitted.height / 2, fitted.width, fitted.height);
}

static inline CGPoint ShackDisplayCanvasPoint(CGPoint point, CGSize canvas, CGRect bounds) {
    CGRect fitted = ShackDisplayCanvasRect(canvas, bounds);
    if (fitted.size.width <= 0) return CGPointZero;
    CGFloat scale = fitted.size.width / canvas.width;
    return CGPointMake((point.x - fitted.origin.x) / scale, (point.y - fitted.origin.y) / scale);
}
#endif
