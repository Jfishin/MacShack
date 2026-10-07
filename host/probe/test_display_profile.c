// clang host/probe/test_display_profile.c -framework CoreGraphics -o /tmp/t && /tmp/t
#include "../../shims/ShackDisplay.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void near(CGFloat a, CGFloat b) { assert(fabs(a-b) < 1e-8); }
static void fit_check(CGRect physical, CGSize virtualSize) {
    CGRect fitted = ShackDisplayCanvasRect(virtualSize, physical);
    assert(fitted.size.width <= physical.size.width + 1e-8);
    assert(fitted.size.height <= physical.size.height + 1e-8);
    near(fitted.size.width/fitted.size.height, virtualSize.width/virtualSize.height);
    near(CGRectGetMidX(fitted), CGRectGetMidX(physical));
    near(CGRectGetMidY(fitted), CGRectGetMidY(physical));
    CGPoint origin = ShackDisplayCanvasPoint(fitted.origin, virtualSize, physical);
    near(origin.x,0); near(origin.y,0);
    CGPoint center = ShackDisplayCanvasPoint(CGPointMake(CGRectGetMidX(fitted),CGRectGetMidY(fitted)),virtualSize,physical);
    near(center.x,virtualSize.width/2); near(center.y,virtualSize.height/2);
    CGPoint end = ShackDisplayCanvasPoint(CGPointMake(CGRectGetMaxX(fitted),CGRectGetMaxY(fitted)),virtualSize,physical);
    near(end.x,virtualSize.width); near(end.y,virtualSize.height);
    for(int i=0;i<=100;i++) {
        CGFloat x=virtualSize.width*i/100, y=virtualSize.height*(100-i)/100;
        CGFloat scale=fitted.size.width/virtualSize.width;
        CGPoint mapped=ShackDisplayCanvasPoint(CGPointMake(fitted.origin.x+x*scale,fitted.origin.y+y*scale),virtualSize,physical);
        near(mapped.x,x); near(mapped.y,y);
    }
}
int main(void) {
    const char *bad[]={NULL,"","960","960X540","960x","x540","-960x540","+960x540","960.0x540","960x540 "," 960x540","960x540x1","0x540","63x540","960x63","8193x540","960x8193","99999999999999999999x540","0000000960x540"};
    for(size_t i=0;i<sizeof bad/sizeof *bad;i++) { CGSize s=CGSizeMake(11,22); assert(!ShackParseDisplaySize(bad[i],&s)); near(s.width,11);near(s.height,22); }
    CGSize s;
    assert(ShackParseDisplaySize("960x540",&s));near(s.width,960);near(s.height,540);
    assert(ShackParseDisplaySize("64x64",NULL));assert(ShackParseDisplaySize("8192x8192",NULL));
    unsetenv("SHACK_DISPLAY_SIZE");assert(!ShackVirtualDisplaySize(&s));
    setenv("SHACK_DISPLAY_SIZE","invalid",1);assert(!ShackVirtualDisplaySize(&s));
    setenv("SHACK_DISPLAY_SIZE","960x540",1);assert(ShackVirtualDisplaySize(&s));near(s.width,960);near(s.height,540);
    fit_check(CGRectMake(0,0,956,440),s);
    fit_check(CGRectMake(0,0,440,956),s);
    fit_check(CGRectMake(10,20,1920,1080),s);
    fit_check(CGRectMake(0,0,1024,768),s);
    CGRect fitted=ShackDisplayCanvasRect(s,CGRectMake(0,0,956,440));
    assert(!CGRectContainsPoint(fitted,CGPointMake(1,220)));
    assert(CGRectContainsPoint(fitted,CGPointMake(478,220)));
    assert(CGRectIsEmpty(ShackDisplayCanvasRect(s,CGRectZero)));
    puts("virtual display parser and geometry: passed");
}
