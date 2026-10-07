#import <Metal/Metal.h>
// Make iOS Metal accept what a macOS Metal renderer sends it (see ShackMetal.m).
void ShackMetalFixups(void);
id<MTLDevice> ShackMetalDevice(void);
unsigned ShackMetalTakeDrawableCount(void);   // nextDrawable calls since the last call
double ShackMetalTakeGPUBusy(void);   // seconds the GPU ran this process's command buffers since the last call
void ShackMetalCaptureFrame(NSString *pngPath);   // writes the next finished frame as a PNG
void ShackMetalCaptureTrace(NSString *gputracePath);   // one-frame GPU trace (needs MTL_CAPTURE_ENABLED=1 at device creation)
// Frame cap: fps is rounded to a whole number of display refreshes (120 Hz: 120/60/40/30/24); 0 = uncapped.
// Call after ShackMetalFixups; again at any time to change it (the island menu).
void ShackMetalSetFrameCap(int fps);
int ShackMetalFrameCap(void);   // the cap in effect, 0 = uncapped
// One line about frame pacing since the last call: how long frames actually stayed on glass.
NSString *ShackMetalTakePacing(void);
// Bytes the Metal device has allocated (buffers, textures, heaps): the GPU share of the app's one memory limit.
uint64_t ShackMetalAllocatedBytes(void);
