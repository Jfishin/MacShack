// MiniCocoa: the smallest AppKit+Metal app that exercises what a game needs.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static const char *kShader =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 pos [[position]]; float4 col; };\n"
"vertex V vmain(uint id [[vertex_id]], constant float &t [[buffer(0)]]) {\n"
"  float2 p[3] = { float2(0, 0.6), float2(-0.6, -0.6), float2(0.6, -0.6) };\n"
"  float c = cos(t), s = sin(t); float2 q = float2(p[id].x*c - p[id].y*s, p[id].x*s + p[id].y*c);\n"
"  V v; v.pos = float4(q, 0, 1); v.col = float4(id == 0, id == 1, id == 2, 1); return v; }\n"
"fragment float4 fmain(V v [[stage_in]]) { return v.col; }\n";

@interface MetalView : NSView
@property (nonatomic) CAMetalLayer *metalLayer;
@property (atomic) float speed;
@end
@implementation MetalView
- (instancetype)initWithFrame:(NSRect)r {
    if ((self = [super initWithFrame:r])) {
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = MTLCreateSystemDefaultDevice();
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.layer = _metalLayer; self.wantsLayer = YES; _speed = 1;
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { NSLog(@"keyDown keyCode=%d chars=%@", e.keyCode, e.characters); self.speed = -self.speed; }
- (void)mouseDown:(NSEvent *)e { NSPoint p = e.locationInWindow; NSLog(@"mouseDown at %.0f,%.0f", p.x, p.y); }
- (void)mouseDragged:(NSEvent *)e { NSPoint p = e.locationInWindow; NSLog(@"mouseDragged at %.0f,%.0f", p.x, p.y); }
@end

@interface Delegate : NSObject <NSApplicationDelegate>
@property NSWindow *window; @property MetalView *view;
@end
@implementation Delegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSLog(@"applicationDidFinishLaunching on main=%d", NSThread.isMainThread);
    NSRect frame = NSMakeRect(100, 100, 800, 500);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"MiniCocoa";
    self.view = [[MetalView alloc] initWithFrame:frame];
    self.window.contentView = self.view;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"screen %@ scale %.1f", NSStringFromRect(NSScreen.mainScreen.frame), self.window.backingScaleFactor);
    [NSThread detachNewThreadWithBlock:^{ [self renderLoop]; }];   // render off the main thread, like engines do
}
- (void)renderLoop {
    id<MTLDevice> dev = self.view.metalLayer.device;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *err; id<MTLLibrary> lib = [dev newLibraryWithSource:@(kShader) options:nil error:&err];
    if (!lib) { NSLog(@"shader error %@", err); return; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vmain"]; d.fragmentFunction = [lib newFunctionWithName:@"fmain"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso) { NSLog(@"pipeline error %@", err); return; }
    float t = 0;
    for (;;) {
        @autoreleasepool {
            CGSize s = self.view.metalLayer.bounds.size;
            CGFloat sc = self.window.backingScaleFactor;
            self.view.metalLayer.drawableSize = CGSizeMake(s.width * sc, s.height * sc);
            id<CAMetalDrawable> dr = [self.view.metalLayer nextDrawable]; if (!dr) continue;
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = dr.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:pso]; [enc setVertexBytes:&t length:sizeof t atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
            [cb presentDrawable:dr]; [cb commit]; [cb waitUntilCompleted];
            t += 0.02f * self.view.speed;
        }
    }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSLog(@"MiniCocoa main() pid=%d exe=%s", getpid(), argv[0]);
        NSApplication *app = [NSApplication sharedApplication];
        Delegate *d = [Delegate new]; app.delegate = d;
        [app run];
    }
    return 0;
}
