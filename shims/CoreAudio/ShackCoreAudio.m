// CoreAudio HAL (AudioObject*/AudioDevice*) with call logging. Re-exports CoreAudio.
// iOS's CoreAudio exports the HAL but its SDK has no AudioHardware.h: the macOS declarations are copied here.
// Answered here, never by iOS's HAL: calling it loads the HAL's plugins into the app, and BTAudioHALPlugin then
// reconnects to a Bluetooth service it cannot reach, without pause: 28% of a core for as long as the game or Steam ran
// (Instruments, 2026-10-04). One built-in output device stands for the phone; RemoteIO (the AudioToolbox shim) plays.
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <Foundation/Foundation.h>
#import <stdatomic.h>

typedef UInt32 AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement;
typedef struct AudioObjectPropertyAddress {
    AudioObjectPropertySelector mSelector; AudioObjectPropertyScope mScope; AudioObjectPropertyElement mElement;
} AudioObjectPropertyAddress;
typedef OSStatus (*AudioObjectPropertyListenerProc)(AudioObjectID inObjectID, UInt32 inNumberAddresses,
                                                    const AudioObjectPropertyAddress *inAddresses, void *inClientData);
typedef OSStatus (*AudioDeviceIOProc)(AudioObjectID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
                                      const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData,
                                      const AudioTimeStamp *inOutputTime, void *inClientData);
typedef AudioDeviceIOProc AudioDeviceIOProcID;

static OSStatus Answer(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 *ioSize, void *out);
static Float64 SessionRate(void);
enum { kShackDevice = 0x5348414B /* 'SHAK' */, kShackStream = 0x5348414C, kShackUnsupported = 0x756E6F70 /* 'unop' */ };
OSStatus AudioDeviceSetProperty(AudioObjectID d, const AudioTimeStamp *when, UInt32 ch, Boolean isInput, UInt32 sel, UInt32 size, const void *data);

Boolean AudioObjectHasProperty(AudioObjectID, const AudioObjectPropertyAddress *);
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
OSStatus AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
OSStatus AudioObjectSetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
OSStatus AudioObjectAddPropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
OSStatus AudioObjectRemovePropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
OSStatus AudioDeviceCreateIOProcID(AudioObjectID, AudioDeviceIOProc, void *, AudioDeviceIOProcID *);
OSStatus AudioDeviceDestroyIOProcID(AudioObjectID, AudioDeviceIOProcID);
OSStatus AudioDeviceStart(AudioObjectID, AudioDeviceIOProcID);
OSStatus AudioDeviceStop(AudioObjectID, AudioDeviceIOProcID);

// ponytail: 20 lines per function, then silent.
#define LOG(fn, fmt, ...) do { static atomic_int n_; if (atomic_fetch_add(&n_, 1) < 20) NSLog(@"[ShackAudio] " #fn fmt, __VA_ARGS__); } while (0)

static NSString *FCC(UInt32 v) {
    char c[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0};
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) return [NSString stringWithFormat:@"%d", (int)v];
    return [NSString stringWithFormat:@"'%s'(%d)", c, (int)v];
}
static NSString *Addr(AudioObjectID o, const AudioObjectPropertyAddress *a) {
    return a ? [NSString stringWithFormat:@"obj %u, %@ scope %@ el %u", (unsigned)o, FCC(a->mSelector), FCC(a->mScope), (unsigned)a->mElement]
             : [NSString stringWithFormat:@"obj %u, NULL", (unsigned)o];
}

Boolean AudioObjectHasProperty(AudioObjectID o, const AudioObjectPropertyAddress *a) {
    UInt32 n = 0; Boolean r = !Answer(o, a, &n, NULL); LOG(AudioObjectHasProperty, @"(%@) -> %d", Addr(o, a), r); return r;
}
Boolean AudioObjectIsPropertySettable(AudioObjectID o, const AudioObjectPropertyAddress *a, Boolean *settable) {   // Chromium
    UInt32 sel = a ? a->mSelector : 0;
    if (settable) *settable = o == kShackDevice && (sel == 'fsiz' || sel == 'nsrt' || sel == 'bsiz');
    return noErr;
}
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *outSize) {
    UInt32 n = 0; OSStatus s = Answer(o, a, &n, NULL);
    if (outSize) *outSize = s ? 0 : n;
    LOG(AudioObjectGetPropertyDataSize, @"(%@) -> %@ size=%u", Addr(o, a), FCC(s), (unsigned)n); return s;
}
OSStatus AudioObjectGetPropertyData(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *ioSize, void *out) {
    OSStatus s;
    if (o == 1 && a && a->mSelector == 'duid' && out && ioSize && *ioSize >= 4 * sizeof(void *)) {   // device for UID: AudioValueTranslation
        AudioObjectID *dev = ((void **)out)[2];   // {input, inputSize, output, outputSize}
        if (dev) *dev = kShackDevice;
        s = noErr;
    } else s = Answer(o, a, ioSize, out);
    LOG(AudioObjectGetPropertyData, @"(%@) -> %@ size=%u", Addr(o, a), FCC(s), ioSize ? (unsigned)*ioSize : 0); return s;
}
OSStatus AudioObjectSetPropertyData(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 size, const void *data) {
    // The session's IO buffer duration and rate are the iOS knobs; every other setting is accepted and has no effect.
    OSStatus s = a ? AudioDeviceSetProperty(o == 1 ? kShackDevice : o, NULL, 0, a->mScope == 'inpt', a->mSelector, size, data) : kAudio_ParamError;
    LOG(AudioObjectSetPropertyData, @"(%@, %u bytes, first u32=%u) -> %@", Addr(o, a), (unsigned)size, data && size >= 4 ? *(const unsigned *)data : 0, FCC(s)); return s;
}
// ponytail: the device never changes, so listeners are never called.
OSStatus AudioObjectAddPropertyListener(AudioObjectID o, const AudioObjectPropertyAddress *a, AudioObjectPropertyListenerProc p, void *c) {
    LOG(AudioObjectAddPropertyListener, @"(%@) -> noErr", Addr(o, a)); return noErr;
}
OSStatus AudioObjectRemovePropertyListener(AudioObjectID o, const AudioObjectPropertyAddress *a, AudioObjectPropertyListenerProc p, void *c) { return noErr; }
// IOProcs on the device: RemoteIO plays through the AudioToolbox shim's output unit instead. ponytail: no game here
// renders with an IOProc; one that does needs a RemoteIO unit calling its proc.
OSStatus AudioDeviceCreateIOProcID(AudioObjectID d, AudioDeviceIOProc proc, void *c, AudioDeviceIOProcID *outID) {
    LOG(AudioDeviceCreateIOProcID, @"(dev %u, %p) -> unsupported", (unsigned)d, proc); return kShackUnsupported;
}
OSStatus AudioDeviceDestroyIOProcID(AudioObjectID d, AudioDeviceIOProcID id) { return noErr; }
OSStatus AudioDeviceStart(AudioObjectID d, AudioDeviceIOProcID id) {
    LOG(AudioDeviceStart, @"(dev %u, %p) -> unsupported", (unsigned)d, id); return kShackUnsupported;
}
OSStatus AudioDeviceDuck(AudioObjectID d, Float32 level, const AudioTimeStamp *start, Float32 duration) { return noErr; }   // Chromium
// --- The pre-10.6 HAL API (AudioHardware*/AudioDevice*), which FMOD (Unity's audio) still uses. iOS's HAL exports
// it but lists no devices, so FMOD gives up ("failed to get number of drivers", no sound). Answer with one built-in
// output device whose numbers come from AVAudioSession; the AudioToolbox shim routes the HAL output unit to RemoteIO
// and accepts kAudioOutputUnitProperty_CurrentDevice for it. Selectors are the macOS AudioHardware.h four-char codes.
enum { kShackUnknownProperty = 0x77686F3F /* 'who?' */, kShackBadSize = 0x2173697A /* '!siz' */, kShackBadDevice = 0x21646576 /* '!dev' */ };
typedef OSStatus (*AudioHardwarePropertyListenerProc)(UInt32 inPropertyID, void *inClientData);
typedef OSStatus (*AudioDevicePropertyListenerProc)(AudioObjectID inDevice, UInt32 inChannel, Boolean isInput, UInt32 inPropertyID, void *inClientData);

static Float64 SessionRate(void) { Float64 r = AVAudioSession.sharedInstance.sampleRate; return r > 0 ? r : 48000; }
static UInt32 SessionFrames(void) { UInt32 f = (UInt32)llround(AVAudioSession.sharedInstance.IOBufferDuration * SessionRate()); return f ? f : 1024; }
static AudioStreamBasicDescription ShackFormat(void) {
    return (AudioStreamBasicDescription){ .mSampleRate = SessionRate(), .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32 };
}
// HAL size protocol: NULL out = size query; too small = error; else copy and report the size written.
static OSStatus Put(UInt32 *ioSize, void *out, const void *src, UInt32 n) {
    if (!ioSize) return kAudio_ParamError;
    if (!out) { *ioSize = n; return noErr; }
    if (*ioSize < n) return kShackBadSize;
    if (n) memcpy(out, src, n);
    *ioSize = n; return noErr;
}
static OSStatus PutCF(UInt32 *ioSize, void *out, CFStringRef s) { if (out) CFRetain(s); return Put(ioSize, out, &s, sizeof s); }
static OSStatus HardwareProp(UInt32 sel, UInt32 *ioSize, void *out) {
    AudioObjectID dev = kShackDevice; UInt32 zero = 0;
    switch (sel) {
    case 'dev#': case 'dOut': case 'sOut': case 'dIn ': return Put(ioSize, out, &dev, sizeof dev);   // device list = the one device, all defaults
    case 'pmut': case 'mixa': case 'slep': return Put(ioSize, out, &zero, sizeof zero);            // process is main, mixing stereo, sleeping wake
    default: return kShackUnknownProperty;
    }
}
static OSStatus DeviceProp(AudioObjectID d, Boolean isInput, UInt32 sel, UInt32 *ioSize, void *out) {
    if (d != kShackDevice) return kShackBadDevice;
    UInt32 zero = 0, one = 1;
    switch (sel) {
    case 'name': return Put(ioSize, out, "iPhone", 7);
    case 'lnam': return PutCF(ioSize, out, CFSTR("iPhone"));
    case 'lmak': return PutCF(ioSize, out, CFSTR("Apple"));
    case 'uid ': return PutCF(ioSize, out, CFSTR("ShackBuiltInOutput"));
    case 'muid': return PutCF(ioSize, out, CFSTR("ShackBuiltInOutput:model"));
    case 'slay': { AudioBufferList l = { isInput ? 0u : 1u, { { 2, 0, NULL } } }; return Put(ioSize, out, &l, sizeof l); }   // one stereo output stream
    case 'stm#': { AudioObjectID s = kShackStream; return Put(ioSize, out, &s, isInput ? 0 : sizeof s); }
    case 'nsrt': { Float64 r = SessionRate(); return Put(ioSize, out, &r, sizeof r); }
    case 'nsr#': { AudioValueRange r = { SessionRate(), SessionRate() }; return Put(ioSize, out, &r, sizeof r); }
    case 'fsiz': { UInt32 f = SessionFrames(); return Put(ioSize, out, &f, sizeof f); }
    case 'bsiz': { UInt32 b = SessionFrames() * 8; return Put(ioSize, out, &b, sizeof b); }
    case 'fsz#': { AudioValueRange r = { 64, 4096 }; return Put(ioSize, out, &r, sizeof r); }
    case 'bsz#': { AudioValueRange r = { 64 * 8, 4096 * 8 }; return Put(ioSize, out, &r, sizeof r); }
    case 'sfmt': case 'sfm#': case 'pft ': case 'pft#': { AudioStreamBasicDescription f = ShackFormat(); return Put(ioSize, out, &f, sizeof f); }
    case 'dch2': { UInt32 ch[2] = { 1, 2 }; return Put(ioSize, out, ch, sizeof ch); }
    case 'srnd': {   // preferred channel layout: left and right, by description (what iOS's HAL device answered, 52 bytes)
        struct { UInt32 tag, bitmap, n; struct { UInt32 label, flags; Float32 coords[3]; } d[2]; } l = { 0, 0, 2, { { 1 }, { 2 } } };
        return Put(ioSize, out, &l, sizeof l);
    }
    case 'ltnc': case 'saft': case 'goin': case 'gone': case 'vfsz': return Put(ioSize, out, &zero, sizeof zero);
    case 'livn': case 'dflt': return Put(ioSize, out, &one, sizeof one);
    case 'oink': { pid_t p = -1; return Put(ioSize, out, &p, sizeof p); }
    case 'tran': { UInt32 t = 'bltn'; return Put(ioSize, out, &t, sizeof t); }
    default: return kShackUnknownProperty;
    }
}
// Any object's property: the system object (1) has the device list and defaults, everything else is the one device.
static OSStatus Answer(AudioObjectID o, const AudioObjectPropertyAddress *a, UInt32 *ioSize, void *out) {
    if (!a) return kAudio_ParamError;
    if (o == 1 /* kAudioObjectSystemObject */) return HardwareProp(a->mSelector, ioSize, out);
    return DeviceProp(o == kShackStream ? kShackDevice : o, a->mScope == 'inpt', a->mSelector, ioSize, out);
}
OSStatus AudioHardwareGetPropertyInfo(UInt32 sel, UInt32 *outSize, Boolean *outWritable) {
    UInt32 n = 0; OSStatus s = HardwareProp(sel, &n, NULL);
    if (outSize) *outSize = n; if (outWritable) *outWritable = false;
    LOG(AudioHardwareGetPropertyInfo, @"(%@) -> %@ size=%u", FCC(sel), FCC(s), (unsigned)n); return s;
}
OSStatus AudioHardwareGetProperty(UInt32 sel, UInt32 *ioSize, void *out) {
    OSStatus s = HardwareProp(sel, ioSize, out);
    LOG(AudioHardwareGetProperty, @"(%@) -> %@ size=%u", FCC(sel), FCC(s), ioSize ? (unsigned)*ioSize : 0); return s;
}
OSStatus AudioHardwareSetProperty(UInt32 sel, UInt32 size, const void *data) { LOG(AudioHardwareSetProperty, @"(%@, %u bytes) -> accepted", FCC(sel), (unsigned)size); return noErr; }
OSStatus AudioHardwareAddPropertyListener(UInt32 sel, AudioHardwarePropertyListenerProc p, void *c) { LOG(AudioHardwareAddPropertyListener, @"(%@) -> noErr", FCC(sel)); return noErr; }
OSStatus AudioHardwareRemovePropertyListener(UInt32 sel, AudioHardwarePropertyListenerProc p) { return noErr; }
OSStatus AudioDeviceGetPropertyInfo(AudioObjectID d, UInt32 ch, Boolean isInput, UInt32 sel, UInt32 *outSize, Boolean *outWritable) {
    UInt32 n = 0; OSStatus s = DeviceProp(d, isInput, sel, &n, NULL);
    if (outSize) *outSize = n; if (outWritable) *outWritable = sel == 'fsiz' || sel == 'nsrt' || sel == 'bsiz';
    LOG(AudioDeviceGetPropertyInfo, @"(dev %u, ch %u, in %d, %@) -> %@ size=%u", (unsigned)d, (unsigned)ch, isInput, FCC(sel), FCC(s), (unsigned)n); return s;
}
OSStatus AudioDeviceGetProperty(AudioObjectID d, UInt32 ch, Boolean isInput, UInt32 sel, UInt32 *ioSize, void *out) {
    OSStatus s = DeviceProp(d, isInput, sel, ioSize, out);
    LOG(AudioDeviceGetProperty, @"(dev %u, ch %u, in %d, %@) -> %@ size=%u", (unsigned)d, (unsigned)ch, isInput, FCC(sel), FCC(s), ioSize ? (unsigned)*ioSize : 0); return s;
}
OSStatus AudioDeviceSetProperty(AudioObjectID d, const AudioTimeStamp *when, UInt32 ch, Boolean isInput, UInt32 sel, UInt32 size, const void *data) {
    AVAudioSession *as = AVAudioSession.sharedInstance;
    if (sel == 'fsiz' && data && size == sizeof(UInt32)) [as setPreferredIOBufferDuration:*(const UInt32 *)data / SessionRate() error:nil];
    if (sel == 'bsiz' && data && size == sizeof(UInt32)) [as setPreferredIOBufferDuration:*(const UInt32 *)data / 8.0 / SessionRate() error:nil];
    if (sel == 'nsrt' && data && size == sizeof(Float64)) [as setPreferredSampleRate:*(const Float64 *)data error:nil];
    LOG(AudioDeviceSetProperty, @"(dev %u, %@, %u bytes, first u32=%u) -> accepted", (unsigned)d, FCC(sel), (unsigned)size, data && size >= 4 ? *(const unsigned *)data : 0);
    return d == kShackDevice ? noErr : kShackBadDevice;   // ponytail: every setting is accepted; the session is the only real knob
}
OSStatus AudioDeviceAddPropertyListener(AudioObjectID d, UInt32 ch, Boolean isInput, UInt32 sel, AudioDevicePropertyListenerProc p, void *c) { return noErr; }
OSStatus AudioDeviceRemovePropertyListener(AudioObjectID d, UInt32 ch, Boolean isInput, UInt32 sel, AudioDevicePropertyListenerProc p) { return noErr; }

OSStatus AudioDeviceStop(AudioObjectID d, AudioDeviceIOProcID id) { return noErr; }
