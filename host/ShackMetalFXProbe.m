#import "ShackMetalFXProbe.h"
#import "ShackMetal.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <stdio.h>
#include <stdarg.h>

static FILE *sLog;
static BOOL sMetalFixups;
// Metal 4 does not retain submitted resources. Keep the small fixture alive even
// if a feedback wait times out; the process must be relaunched before a game.
static NSMutableArray *sKeepAlive;

static void FXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void FXLog(NSString *format, ...) {
    va_list ap; va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    @synchronized (sKeepAlive) {
        if (sLog) { fprintf(sLog, "%s\n", line.UTF8String); fflush(sLog); }
        NSLog(@"[Metal4FXProbe] %@", line);
    }
}

static id<MTLTexture> FXTexture(id<MTLDevice> device, NSString *label,
                               MTLPixelFormat format, NSUInteger width,
                               NSUInteger height, MTLTextureUsage usage) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                width:width height:height mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = usage | MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    texture.label = label;
    if (texture) [sKeepAlive addObject:texture];
    FXLog(@"texture %@ class=%@ format=%lu size=%lux%lu usage=0x%lx storage=%lu", label,
          texture ? NSStringFromClass([texture class]) : @"nil", (unsigned long)format,
          (unsigned long)width, (unsigned long)height, (unsigned long)td.usage,
          (unsigned long)td.storageMode);
    return texture;
}

API_AVAILABLE(ios(26.0), macos(26.0))
static BOOL FXSubmit(id<MTL4CommandQueue> queue, id<MTL4CommandBuffer> buffer,
                     NSString *phase) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL accepted = NO;
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        accepted = feedback.error == nil;
        FXLog(@"feedback %@ error=%@ GPUStart=%.9f GPUEnd=%.9f", phase,
              feedback.error ?: @"none", feedback.GPUStartTime, feedback.GPUEndTime);
        dispatch_semaphore_signal(done);
    }];
    [buffer endCommandBuffer];
    FXLog(@"commit %@", phase);
    id<MTL4CommandBuffer> buffers[] = { buffer };
    [queue commit:buffers count:1 options:options];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        FXLog(@"FAIL %@: no completion feedback within 10 seconds; resources retained", phase);
        return NO;
    }
    return accepted;
}

API_AVAILABLE(ios(26.0), macos(26.0))
static void FXRun(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { FXLog(@"FAIL no native Metal device"); return; }
    [sKeepAlive addObject:device];
    FXLog(@"device=%@ class=%@ OS=%@ validation=%s", device.name,
          NSStringFromClass([device class]), NSProcessInfo.processInfo.operatingSystemVersionString,
          getenv("MTL_DEBUG_LAYER") ?: "unset");
    BOOL supported = [MTLFXTemporalScalerDescriptor supportsMetal4FX:device];
    FXLog(@"supportsMetal4FX=%d inputContentScale=[%g,%g]", supported,
          [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device],
          [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device]);
    if (!supported) { FXLog(@"UNSUPPORTED native Metal4FX temporal scaling"); return; }

    NSError *error = nil;
    id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
    if (!compiler) { FXLog(@"FAIL compiler %@", error); return; }
    [sKeepAlive addObject:compiler];
    MTLFXTemporalScalerDescriptor *desc = [MTLFXTemporalScalerDescriptor new];
    desc.inputWidth = 320; desc.inputHeight = 180;
    desc.outputWidth = 960; desc.outputHeight = 540;
    desc.colorTextureFormat = MTLPixelFormatRGBA16Float;
    desc.depthTextureFormat = MTLPixelFormatDepth32Float;
    desc.motionTextureFormat = MTLPixelFormatRG16Float;
    desc.outputTextureFormat = MTLPixelFormatRGBA16Float;
    desc.autoExposureEnabled = YES;
    desc.requiresSynchronousInitialization = NO;
    desc.inputContentPropertiesEnabled = NO;
    desc.reactiveMaskTextureEnabled = NO;
    FXLog(@"factory descriptor=%@ compiler=%@ input=320x180 output=960x540 color=%lu depth=%lu motion=%lu output=%lu autoExposure=1 synchronous=0 dynamic=0 reactive=0",
          NSStringFromClass([desc class]), NSStringFromClass([compiler class]),
          (unsigned long)desc.colorTextureFormat, (unsigned long)desc.depthTextureFormat,
          (unsigned long)desc.motionTextureFormat, (unsigned long)desc.outputTextureFormat);
    id<MTL4FXTemporalScaler> scaler = [desc newTemporalScalerWithDevice:device compiler:compiler];
    if (!scaler) { FXLog(@"FAIL native scaler factory returned nil"); return; }
    [sKeepAlive addObject:scaler];
    FXLog(@"scaler=%@", NSStringFromClass([scaler class]));
    id<MTLTexture> color = FXTexture(device, @"probe-color", desc.colorTextureFormat, 320, 180, scaler.colorTextureUsage);
    id<MTLTexture> depth = FXTexture(device, @"probe-depth", desc.depthTextureFormat, 320, 180, scaler.depthTextureUsage);
    id<MTLTexture> motion = FXTexture(device, @"probe-motion", desc.motionTextureFormat, 320, 180, scaler.motionTextureUsage);
    id<MTLTexture> output = FXTexture(device, @"probe-output", desc.outputTextureFormat, 960, 540, scaler.outputTextureUsage);
    if (!color || !depth || !motion || !output) { FXLog(@"FAIL texture allocation"); return; }
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    rd.label = @"Metal4FX probe textures";
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:rd error:&error];
    if (!queue || !residency) { FXLog(@"FAIL queue/residency %@", error); return; }
    [sKeepAlive addObjectsFromArray:@[queue, residency]];
    for (id<MTLTexture> texture in @[color, depth, motion, output]) [residency addAllocation:texture];
    [residency commit];
    [queue addResidencySet:residency];

    id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
    id<MTL4CommandBuffer> clear = [device newCommandBuffer];
    if (!allocator || !clear) { FXLog(@"FAIL clear allocator/buffer"); return; }
    [sKeepAlive addObjectsFromArray:@[allocator, clear]];
    [clear beginCommandBufferWithAllocator:allocator];
    // Known static scene: constant color, far-plane depth, zero motion. No shader
    // compilation or guest state participates in input initialization.
    for (id<MTLTexture> texture in @[color, motion, output]) {
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = texture == color ? MTLClearColorMake(0.25, 0.5, 0.75, 1) : MTLClearColorMake(0, 0, 0, 0);
        if (texture == color) {
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = 1;
        }
        id<MTL4RenderCommandEncoder> encoder = [clear renderCommandEncoderWithDescriptor:pass];
        if (!encoder) { FXLog(@"FAIL native clear encoder"); return; }
        [encoder endEncoding];
    }
    if (!FXSubmit(queue, clear, @"initialize-inputs")) return;
    scaler.colorTexture = color; scaler.depthTexture = depth;
    scaler.motionTexture = motion; scaler.outputTexture = output;
    scaler.inputContentWidth = 320; scaler.inputContentHeight = 180;
    scaler.preExposure = 1; scaler.depthReversed = NO;
    scaler.motionVectorScaleX = 1; scaler.motionVectorScaleY = 1;
    scaler.jitterOffsetX = 0; scaler.jitterOffsetY = 0;
    for (NSUInteger frame = 0; frame < 3; ++frame) {
        id<MTL4CommandAllocator> frameAllocator = [device newCommandAllocator];
        id<MTL4CommandBuffer> buffer = [device newCommandBuffer];
        if (!frameAllocator || !buffer) { FXLog(@"FAIL frame allocator/buffer"); return; }
        [sKeepAlive addObjectsFromArray:@[frameAllocator, buffer]];
        buffer.label = [NSString stringWithFormat:@"Metal4FX probe frame %lu", (unsigned long)frame];
        [buffer beginCommandBufferWithAllocator:frameAllocator];
        scaler.reset = frame == 0;
        FXLog(@"encode frame=%lu reset=%d", (unsigned long)frame, scaler.reset);
        [scaler encodeToCommandBuffer:buffer];
        FXLog(@"encode returned frame=%lu", (unsigned long)frame);
        if (!FXSubmit(queue, buffer, buffer.label)) return;
    }
    FXLog(@"PASS 3 native Metal4FX temporal frames completed; %@; no guest, bundle redirection, or guest filesystem hooks; output appearance not assessed",
          sMetalFixups ? @"Metal adaptations enabled" : @"Metal adaptations disabled");
}

void ShackMetalFXProbe(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool {
        sKeepAlive = [NSMutableArray new];
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *logs = [documents URLByAppendingPathComponent:@"Logs" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:logs withIntermediateDirectories:YES attributes:nil error:nil];
        sLog = fopen([[logs URLByAppendingPathComponent:@"metal4-fx-probe.log"] fileSystemRepresentation], "w");
        const char *fixups = getenv("SHACK_FX_PROBE_FIXUPS");
        sMetalFixups = fixups && !strcmp(fixups, "1");
        FXLog(@"BEGIN standalone native Metal4FX probe; Metal adaptations=%d; relaunch app before loading a game", sMetalFixups);
        @try {
            if (@available(iOS 26.0, macOS 26.0, *)) {
                if (sMetalFixups) {
                    FXLog(@"installing ShackMetalFixups on main queue; no ShackHooksInstall");
                    if (NSThread.isMainThread) ShackMetalFixups();
                    else dispatch_sync(dispatch_get_main_queue(), ^{ ShackMetalFixups(); });
                    FXLog(@"Metal adaptations installed");
                }
                FXRun();
            }
            else FXLog(@"UNSUPPORTED OS requires Metal 4");
        } @catch (NSException *exception) {
            FXLog(@"EXCEPTION %@: %@", exception.name, exception.reason);
        }
        FXLog(@"END");
    }});
}
