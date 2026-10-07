// IOKit display info and KextManager for UE4's hardware survey. Re-exports IOKit.
#import <Foundation/Foundation.h>
#import <mach/mach.h>

typedef mach_port_t io_service_t;
typedef UInt32 IOOptionBits;

CFDictionaryRef IODisplayCreateInfoDictionary(io_service_t framebuffer, IOOptionBits options) {
    return CFBridgingRetain(@{@"DisplayProductName": @{@"en_US": @"iPhone"}});
}
// ponytail: no kexts on iOS; NULL is the documented "none/failed" answer for both.
CFDictionaryRef KextManagerCopyLoadedKextInfo(CFArrayRef kextIdentifiers, CFArrayRef infoKeys) { return NULL; }
CFURLRef KextManagerCreateURLForBundleIdentifier(CFAllocatorRef allocator, CFStringRef kextIdentifier) { return NULL; }
// Display parameters (brightness; Cyberpunk 2077): kIOReturnUnsupported, as for a display without them.
int IODisplayGetFloatParameter(io_service_t service, IOOptionBits options, CFStringRef parameterName, float *value) { return (int)0xe00002c7; }

// The sandbox refuses IOPMrootDomain, so the real call returns 0 with a NULL port and Unity (PlayerMain) passes that
// port to IONotificationPortGetRunLoopSource. ponytail: a real, silent port; iOS apps get no system-sleep messages.
typedef struct IONotificationPort *IONotificationPortRef;
extern IONotificationPortRef IONotificationPortCreate(mach_port_t mainPort);
mach_port_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *port, void *callback, io_service_t *notifier) {
    if (port) *port = IONotificationPortCreate(MACH_PORT_NULL);
    if (notifier) *notifier = MACH_PORT_NULL;
    return 0xFFFF1000;   // nonzero = success; only ever handed back to IOAllowPowerChange/IOServiceClose
}
int IODeregisterForSystemPower(io_service_t *notifier) { return 0; }

// ForceFeedback (macOS rumble for HID joysticks): no device supports it here, so SDL2 and friends skip haptics.
// ponytail: GameController pads could rumble through GCController haptics; wire FFEffectStart to them when a game needs it.
typedef int32_t HRESULT;
enum { FFERR_UNSUPPORTED = (int32_t)0x80040200, FFERR_NOINTERFACE = (int32_t)0x80000004 };
HRESULT FFIsForceFeedback(io_service_t device) { return FFERR_NOINTERFACE; }
HRESULT FFCreateDevice(io_service_t device, void **deviceRef) { if (deviceRef) *deviceRef = NULL; return FFERR_NOINTERFACE; }
HRESULT FFReleaseDevice(void *deviceRef) { return FFERR_UNSUPPORTED; }
HRESULT FFDeviceGetForceFeedbackCapabilities(void *deviceRef, void *caps) { return FFERR_UNSUPPORTED; }
HRESULT FFDeviceGetForceFeedbackProperty(void *deviceRef, uint32_t property, void *value, uint32_t size) { return FFERR_UNSUPPORTED; }
HRESULT FFDeviceSetForceFeedbackProperty(void *deviceRef, uint32_t property, void *value) { return FFERR_UNSUPPORTED; }
HRESULT FFDeviceSendForceFeedbackCommand(void *deviceRef, uint32_t command) { return FFERR_UNSUPPORTED; }
HRESULT FFDeviceCreateEffect(void *deviceRef, CFUUIDRef type, void *effect, void **effectRef) { if (effectRef) *effectRef = NULL; return FFERR_UNSUPPORTED; }
HRESULT FFDeviceReleaseEffect(void *deviceRef, void *effectRef) { return FFERR_UNSUPPORTED; }
HRESULT FFEffectSetParameters(void *effectRef, void *effect, uint32_t flags) { return FFERR_UNSUPPORTED; }
HRESULT FFEffectStart(void *effectRef, uint32_t iterations, uint32_t flags) { return FFERR_UNSUPPORTED; }
HRESULT FFEffectStop(void *effectRef) { return FFERR_UNSUPPORTED; }
HRESULT FFEffectGetEffectStatus(void *effectRef, uint32_t *status) { if (status) *status = 0; return FFERR_UNSUPPORTED; }
