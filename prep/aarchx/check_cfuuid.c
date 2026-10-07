// Feral's HID pad setup (BioShock) builds kIOHIDDeviceInterfaceID with CFUUIDGetConstantUUIDWithBytes: 17 arguments,
// 11 on the stack, which the arm64 call packs at one byte each. Then it asks for an IOKit plug-in, which must return
// an error, not end the process (on the phone MacShack refuses it; on the Mac real IOKit fails on a bogus service).
// clang -arch x86_64 -framework IOKit -framework CoreFoundation check_cfuuid.c -o /tmp/c && ./ocerz -native /tmp/c   # cfuuid ok
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    static const UInt8 want[16] = {0x78, 0xBD, 0x42, 0x0C, 0x6F, 0x14, 0x11, 0xD4, 0x94, 0x74, 0x00, 0x05, 0x02, 0x8F, 0x18, 0xD5};
    CFUUIDRef u = CFUUIDGetConstantUUIDWithBytes(NULL, 0x78, 0xBD, 0x42, 0x0C, 0x6F, 0x14, 0x11, 0xD4,
                                                 0x94, 0x74, 0x00, 0x05, 0x02, 0x8F, 0x18, 0xD5);
    CFUUIDBytes b = u ? CFUUIDGetUUIDBytes(u) : (CFUUIDBytes){0};
    if (!u || memcmp(&b, want, 16)) {
        printf("cfuuid FAIL: %p\n", (void *)u);
        return 1;
    }
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(0x53480001, kIOHIDDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) == 0) {
        printf("cfuuid FAIL: a plug-in for a bogus service\n");
        return 1;
    }
    printf("cfuuid ok\n");
    return 0;
}
