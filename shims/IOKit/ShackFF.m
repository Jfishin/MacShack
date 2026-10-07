// ForceFeedback (the IOKit shim serves it): iOS has no HID force-feedback devices, so a game's rumble effects fail
// the way they do on a Mac without a rumble pad. GameController haptics are not routed here.
#import <Foundation/Foundation.h>
enum { kShackFFUnsupported = (int)0x80000004 };   // FFERR_UNSUPPORTED
int32_t FFDeviceEscape(void *device, void *escape) { return kShackFFUnsupported; }
int32_t FFEffectDownload(void *effect) { return kShackFFUnsupported; }
