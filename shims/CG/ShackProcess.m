// ApplicationServices' Process Manager (what a Mac game of 2016 still calls to bring itself to the front) and two CG
// display calls. iOS runs one process that is always frontmost: every call succeeds and answers "this process".
// Feral Interactive's launcher (BioShock Remastered) calls GetCurrentProcess before its game loop starts.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <unistd.h>

typedef struct { UInt32 highLongOfPSN, lowLongOfPSN; } ShackPSN;
enum { kShackCurrentProcess = 2, kShackUnimp = -4 };

int32_t GetCurrentProcess(ShackPSN *psn) { if (psn) { psn->highLongOfPSN = 0; psn->lowLongOfPSN = kShackCurrentProcess; } return 0; }
int32_t GetFrontProcess(ShackPSN *psn) { return GetCurrentProcess(psn); }
int32_t SetFrontProcess(const ShackPSN *psn) { return 0; }
int32_t SetFrontProcessWithOptions(const ShackPSN *psn, UInt32 options) { return 0; }
int32_t GetProcessPID(const ShackPSN *psn, pid_t *pid) { if (pid) *pid = getpid(); return 0; }
int32_t GetProcessForPID(pid_t pid, ShackPSN *psn) { return pid == getpid() ? GetCurrentProcess(psn) : -600; }   // procNotFound
int16_t SameProcess(const ShackPSN *a, const ShackPSN *b, Boolean *same) { if (same) *same = a && b && a->lowLongOfPSN == b->lowLongOfPSN && a->highLongOfPSN == b->highLongOfPSN; return 0; }
// The app's own bundle as an FSRef (Carbon shim, ShackLegacy.m): Feral's launcher derives its install folder, and from that
// its data folder, from it.
int32_t GetProcessBundleLocation(const ShackPSN *psn, void *fsref) {
    void (*make)(NSString *, void *) = dlsym(RTLD_DEFAULT, "ShackFSRefMake");
    if (!make || !fsref) return kShackUnimp;
    make(NSBundle.mainBundle.bundlePath, fsref);
    return 0;
}
int16_t LaunchApplication(void *params) { return kShackUnimp; }

void CGDisplayRestoreColorSyncSettings(void) {}
int32_t CGSetLocalEventsSuppressionInterval(double seconds) { return 0; }
