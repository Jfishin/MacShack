// AudioToolbox with call logging; the macOS default/HAL output unit becomes RemoteIO. Re-exports AudioToolbox.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // AUGraph: deprecated, still what UE4 calls
#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#import <time.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <os/lock.h>

static void *Lib(void) {
    static void *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW); });
    return h;
}
// The real function: a direct call would bind to our own definition.
#define REAL(fn) ({ static __typeof__(&fn) r_; if (!r_) r_ = (__typeof__(&fn))dlsym(Lib(), #fn); r_; })
// ponytail: 20 lines per function, then silent.
#define LOG(fn, fmt, ...) do { static atomic_int n_; if (atomic_fetch_add(&n_, 1) < 20) NSLog(@"[ShackAudio] " #fn fmt, __VA_ARGS__); } while (0)

static NSString *FCC(UInt32 v) {
    char c[5] = {(char)(v >> 24), (char)(v >> 16), (char)(v >> 8), (char)v, 0};
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) return [NSString stringWithFormat:@"%d", (int)v];
    return [NSString stringWithFormat:@"'%s'(%d)", c, (int)v];
}
static NSString *Desc(const AudioComponentDescription *d) {
    return d ? [NSString stringWithFormat:@"%@/%@/%@", FCC(d->componentType), FCC(d->componentSubType), FCC(d->componentManufacturer)] : @"NULL";
}
static NSString *ASBD(const AudioStreamBasicDescription *f) {
    return f ? [NSString stringWithFormat:@"%.0fHz %@ flags=0x%x %uch %ubit %uB/frame", f->mSampleRate, FCC(f->mFormatID),
                (unsigned)f->mFormatFlags, (unsigned)f->mChannelsPerFrame, (unsigned)f->mBitsPerChannel, (unsigned)f->mBytesPerFrame] : @"NULL";
}

// Everything the game has playing. A game that ends with _Exit/exit no longer ends the process (the host goes back to
// Home), so the system would keep calling its audio callbacks; ShackAudioStopAll silences them when the game ends.
static NSMutableSet<NSValue *> *gQueues, *gUnits, *gGraphs;
// Units already disposed: a Mac AudioUnit is a checked handle, so a game may stop one again after disposing it (FMOD
// Studio tearing down a failed init); here it is freed memory. Such calls get kAudio_ParamError, as on a Mac.
static NSMutableSet<NSValue *> *gDisposed;
static BOOL Disposed(const void *u) { @synchronized(NSValue.class) { return [gDisposed containsObject:[NSValue valueWithPointer:u]]; } }
static void Track(NSMutableSet<NSValue *> * __strong *set, const void *p, BOOL on) {
    @synchronized(NSValue.class) {
        if (!*set) *set = [NSMutableSet set];
        NSValue *v = [NSValue valueWithPointer:p];
        if (on) [*set addObject:v]; else [*set removeObject:v];
    }
}
// RemoteIO renders nothing until the app's audio session is active.
static void ActivateSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVAudioSession *as = AVAudioSession.sharedInstance; NSError *e1 = nil, *e2 = nil;
        BOOL ok = [as setCategory:AVAudioSessionCategoryPlayback error:&e1] && [as setActive:YES error:&e2];
        NSLog(@"[ShackAudio] AVAudioSession playback active=%d rate=%.0f %@", ok, as.sampleRate, e1 ?: e2 ?: @"");
    });
}
// A Mac HAL unit calls back with the device's buffer, 512 frames by default; RemoteIO with the session's, about 1024 on
// an iPhone. FMOD mixes ahead only its own DSP buffers and answers a bigger request with silence (Okko: 2 x 256
// frames, so every 941-frame callback was zeros), so a HAL unit gets the Mac's 512. A guest's own 'fsiz' still wins.
static void MacBufferSize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVAudioSession *as = AVAudioSession.sharedInstance;
        [as setPreferredIOBufferDuration:512.0 / (as.sampleRate > 0 ? as.sampleRate : 48000) error:nil];
    });
}
// iOS has no 'def '/'ahal' output unit; RemoteIO is the equivalent (bus 0 = speaker).
// ponytail: output only; a macOS guest asking for HAL input gets RemoteIO without EnableIO on bus 1.
static AudioComponentDescription FixDesc(const AudioComponentDescription *d) {
    AudioComponentDescription r = *d;
    if (r.componentType == kAudioUnitType_Output && (r.componentSubType == 'def ' || r.componentSubType == 'ahal')) {
        r.componentSubType = kAudioUnitSubType_RemoteIO; ActivateSession(); MacBufferSize();
    }
    return r;
}

// Counts the guest's render callbacks; the context is never freed, so a render racing a
// callback swap or AUGraphStop still sees a valid one. ponytail: leaks 16 bytes per set.
typedef struct { AURenderCallback proc; void *ref; } Tramp;
static atomic_ullong gRendered;
static OSStatus Counted(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    static _Atomic uint64_t lastLog;
    const Tramp *t = ref;
    unsigned long long n = atomic_fetch_add(&gRendered, 1) + 1;
    OSStatus s = t->proc(t->ref, flags, ts, bus, frames, io);
    // Loudest sample since the last report (float samples assumed): silence vs sound, including short effects.
    static _Atomic float peakSince;
    float peak = 0;
    if (io && io->mNumberBuffers) for (UInt32 i = 0; i < io->mBuffers[0].mDataByteSize / 4; i++) peak = fmaxf(peak, fabsf(((const float *)io->mBuffers[0].mData)[i]));
    if (peak > peakSince) peakSince = peak;   // ponytail: racy max, fine for a diagnostic
    // SHACK_AUDIO_DUMP=1: the first 500 rendered buffers, raw, to Documents/Logs/audio-dump.raw (what the game wrote).
    static FILE *dump; static int dumped = -1;
    if (dumped < 0) {
        dumped = 0;
        if (getenv("SHACK_AUDIO_DUMP")) {
            NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs/audio-dump.raw"];
            dump = fopen(p.fileSystemRepresentation, "wb");
        }
    }
    if (dump && dumped < 500 && io && io->mNumberBuffers) {
        fwrite(io->mBuffers[0].mData, 1, io->mBuffers[0].mDataByteSize, dump);
        if (++dumped == 500) { fclose(dump); dump = NULL; }
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), last = lastLog;
    // ponytail: NSLog on the render thread, once per 60 s.
    if (now - last >= 60000000000ull && atomic_compare_exchange_strong(&lastLog, &last, now)) {
        NSLog(@"[ShackAudio] rendered %llu buffers (%u frames), status %d, peak %.4f this minute", n, (unsigned)frames, (int)s, (float)peakSince);
        peakSince = 0;
    }
    return s;
}

// --- AUGraph
OSStatus NewAUGraph(AUGraph *outGraph) { OSStatus s = REAL(NewAUGraph)(outGraph); LOG(NewAUGraph, @"() -> %@ %p", FCC(s), outGraph ? *outGraph : NULL); return s; }
OSStatus DisposeAUGraph(AUGraph g) { OSStatus s = REAL(DisposeAUGraph)(g); LOG(DisposeAUGraph, @"(%p) -> %@", g, FCC(s)); return s; }
OSStatus AUGraphAddNode(AUGraph g, const AudioComponentDescription *d, AUNode *outNode) {
    AudioComponentDescription f = d ? FixDesc(d) : (AudioComponentDescription){0};
    OSStatus s = REAL(AUGraphAddNode)(g, d ? &f : NULL, outNode); LOG(AUGraphAddNode, @"(%p, %@) -> %@ node=%d", g, Desc(d ? &f : NULL), FCC(s), outNode ? (int)*outNode : -1); return s;
}
OSStatus AUGraphRemoveNode(AUGraph g, AUNode n) { OSStatus s = REAL(AUGraphRemoveNode)(g, n); LOG(AUGraphRemoveNode, @"(%p, %d) -> %@", g, (int)n, FCC(s)); return s; }
OSStatus AUGraphConnectNodeInput(AUGraph g, AUNode src, UInt32 srcOut, AUNode dst, UInt32 dstIn) {
    OSStatus s = REAL(AUGraphConnectNodeInput)(g, src, srcOut, dst, dstIn); LOG(AUGraphConnectNodeInput, @"(%p, %d:%u -> %d:%u) -> %@", g, (int)src, (unsigned)srcOut, (int)dst, (unsigned)dstIn, FCC(s)); return s;
}
OSStatus AUGraphDisconnectNodeInput(AUGraph g, AUNode dst, UInt32 dstIn) {
    OSStatus s = REAL(AUGraphDisconnectNodeInput)(g, dst, dstIn); LOG(AUGraphDisconnectNodeInput, @"(%p, %d:%u) -> %@", g, (int)dst, (unsigned)dstIn, FCC(s)); return s;
}
OSStatus AUGraphSetNodeInputCallback(AUGraph g, AUNode dst, UInt32 dstIn, const AURenderCallbackStruct *cb) {
    AURenderCallbackStruct w = {0};
    if (cb && cb->inputProc) {
        Tramp *t = malloc(sizeof *t); *t = (Tramp){cb->inputProc, cb->inputProcRefCon};
        w = (AURenderCallbackStruct){Counted, t}; cb = &w;
    }
    OSStatus s = REAL(AUGraphSetNodeInputCallback)(g, dst, dstIn, cb); LOG(AUGraphSetNodeInputCallback, @"(%p, %d:%u, %p) -> %@", g, (int)dst, (unsigned)dstIn, cb ? (void *)cb->inputProc : NULL, FCC(s)); return s;
}
OSStatus AUGraphNodeInfo(AUGraph g, AUNode n, AudioComponentDescription *outDesc, AudioUnit *outUnit) {
    OSStatus s = REAL(AUGraphNodeInfo)(g, n, outDesc, outUnit); LOG(AUGraphNodeInfo, @"(%p, %d) -> %@ unit=%p", g, (int)n, FCC(s), outUnit ? *outUnit : NULL); return s;
}
OSStatus AUGraphOpen(AUGraph g) { OSStatus s = REAL(AUGraphOpen)(g); LOG(AUGraphOpen, @"(%p) -> %@", g, FCC(s)); return s; }
OSStatus AUGraphInitialize(AUGraph g) { OSStatus s = REAL(AUGraphInitialize)(g); LOG(AUGraphInitialize, @"(%p) -> %@", g, FCC(s)); return s; }
OSStatus AUGraphUpdate(AUGraph g, Boolean *outIsUpdated) { OSStatus s = REAL(AUGraphUpdate)(g, outIsUpdated); LOG(AUGraphUpdate, @"(%p) -> %@", g, FCC(s)); return s; }
OSStatus AUGraphStart(AUGraph g) { OSStatus s = REAL(AUGraphStart)(g); if (!s) Track(&gGraphs, g, YES); LOG(AUGraphStart, @"(%p) -> %@", g, FCC(s)); return s; }
OSStatus AUGraphStop(AUGraph g) { OSStatus s = REAL(AUGraphStop)(g); Track(&gGraphs, g, NO); LOG(AUGraphStop, @"(%p) -> %@", g, FCC(s)); return s; }

// --- AudioComponent / AudioUnit
AudioComponent AudioComponentFindNext(AudioComponent inComponent, const AudioComponentDescription *d) {
    AudioComponentDescription f = d ? FixDesc(d) : (AudioComponentDescription){0};
    AudioComponent c = REAL(AudioComponentFindNext)(inComponent, d ? &f : NULL);
    LOG(AudioComponentFindNext, @"(%p, %@) -> %@", inComponent, Desc(d ? &f : NULL), c ? @"found" : @"NULL"); return c;
}
OSStatus AudioComponentInstanceNew(AudioComponent c, AudioComponentInstance *out) {
    OSStatus s = REAL(AudioComponentInstanceNew)(c, out); if (!s && out) Track(&gDisposed, *out, NO); LOG(AudioComponentInstanceNew, @"(%p) -> %@ %p", c, FCC(s), out ? *out : NULL); return s;
}
OSStatus AudioComponentInstanceDispose(AudioComponentInstance i) { if (Disposed(i)) return kAudio_ParamError; OSStatus s = REAL(AudioComponentInstanceDispose)(i); if (!s) Track(&gDisposed, i, YES); LOG(AudioComponentInstanceDispose, @"(%p) -> %@", i, FCC(s)); return s; }
AudioComponent AudioComponentRegister(const AudioComponentDescription *d, CFStringRef name, UInt32 version, AudioComponentFactoryFunction factory) {
    AudioComponent c = REAL(AudioComponentRegister)(d, name, version, factory); LOG(AudioComponentRegister, @"(%@, %@) -> %p", Desc(d), name, c); return c;
}
OSStatus AudioUnitInitialize(AudioUnit u) { OSStatus s = REAL(AudioUnitInitialize)(u); LOG(AudioUnitInitialize, @"(%p) -> %@", u, FCC(s)); return s; }
OSStatus AudioUnitUninitialize(AudioUnit u) { return Disposed(u) ? kAudio_ParamError : REAL(AudioUnitUninitialize)(u); }
OSStatus AudioUnitReset(AudioUnit u, AudioUnitScope sc, AudioUnitElement el) { return Disposed(u) ? kAudio_ParamError : REAL(AudioUnitReset)(u, sc, el); }
enum { kShackHALDevice = 0x5348414B };   // the CoreAudio shim's one output device ('SHAK')
static Float64 SessionRate(void) { Float64 r = AVAudioSession.sharedInstance.sampleRate; return r > 0 ? r : 48000; }
OSStatus AudioUnitGetProperty(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc, AudioUnitElement el, void *out, UInt32 *ioSize) {
    if (p == kAudioOutputUnitProperty_CurrentDevice && out && ioSize && *ioSize >= sizeof(UInt32)) { *(UInt32 *)out = kShackHALDevice; *ioSize = sizeof(UInt32); return noErr; }
    if (p == 'fsiz' && out && ioSize && *ioSize >= sizeof(UInt32)) {   // kAudioDevicePropertyBufferFrameSize read through the unit
        UInt32 f = (UInt32)llround(AVAudioSession.sharedInstance.IOBufferDuration * SessionRate());
        *(UInt32 *)out = f ? f : 1024; *ioSize = sizeof(UInt32); return noErr;
    }
    OSStatus s = REAL(AudioUnitGetProperty)(u, p, sc, el, out, ioSize);
    // RemoteIO reports its hardware-side format with a 0 Hz rate before the first render; a HAL unit never does.
    if (p == kAudioUnitProperty_StreamFormat && s == noErr && out && ioSize && *ioSize >= sizeof(AudioStreamBasicDescription) && ((AudioStreamBasicDescription *)out)->mSampleRate == 0)
        ((AudioStreamBasicDescription *)out)->mSampleRate = SessionRate();
    LOG(AudioUnitGetProperty, @"(%p, %u, scope %u, el %u) -> %@", u, (unsigned)p, (unsigned)sc, (unsigned)el, FCC(s)); return s;
}
// A HAL unit notifies 'fsiz' listeners when the buffer size changes, and cubeb (the Sly Cooper port's audio) waits 3 s
// for that before it gives up on the stream. RemoteIO has no such property, so the shim keeps those listeners itself.
// ponytail: a fixed table; 8 is plenty for one game's units.
static struct { AudioUnit unit; AudioUnitPropertyListenerProc proc; void *data; } gSizeListeners[8];
static os_unfair_lock gSizeLock = OS_UNFAIR_LOCK_INIT;
OSStatus AudioUnitAddPropertyListener(AudioUnit u, AudioUnitPropertyID p, AudioUnitPropertyListenerProc proc, void *data) {
    if (p != 'fsiz') return REAL(AudioUnitAddPropertyListener)(u, p, proc, data);
    OSStatus s = kAudio_MemFullError;
    os_unfair_lock_lock(&gSizeLock);
    for (int i = 0; i < 8; i++) if (!gSizeListeners[i].unit) { gSizeListeners[i].unit = u; gSizeListeners[i].proc = proc; gSizeListeners[i].data = data; s = noErr; break; }
    os_unfair_lock_unlock(&gSizeLock);
    return s;
}
OSStatus AudioUnitRemovePropertyListenerWithUserData(AudioUnit u, AudioUnitPropertyID p, AudioUnitPropertyListenerProc proc, void *data) {
    if (p != 'fsiz') return REAL(AudioUnitRemovePropertyListenerWithUserData)(u, p, proc, data);
    os_unfair_lock_lock(&gSizeLock);
    for (int i = 0; i < 8; i++) if (gSizeListeners[i].unit == u && gSizeListeners[i].proc == proc && gSizeListeners[i].data == data) gSizeListeners[i].unit = NULL;
    os_unfair_lock_unlock(&gSizeLock);
    return noErr;
}
static void NotifySizeListeners(AudioUnit u, AudioUnitScope sc, AudioUnitElement el) {
    typeof(gSizeListeners) copy;
    os_unfair_lock_lock(&gSizeLock); memcpy(copy, gSizeListeners, sizeof copy); os_unfair_lock_unlock(&gSizeLock);
    for (int i = 0; i < 8; i++) if (copy[i].unit == u) copy[i].proc(copy[i].data, u, 'fsiz', sc, el);
}
OSStatus AudioUnitSetProperty(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc, AudioUnitElement el, const void *data, UInt32 size) {
    // A macOS HAL output unit takes a device id and a device buffer size; RemoteIO has neither (the session does).
    if (p == kAudioOutputUnitProperty_CurrentDevice) { LOG(AudioUnitSetProperty, @"(%p, CurrentDevice %u) -> accepted", u, data && size >= 4 ? *(const unsigned *)data : 0); return noErr; }
    if (p == 'fsiz' && data && size == sizeof(UInt32)) {   // kAudioDevicePropertyBufferFrameSize set through the unit
        AVAudioSession *as = AVAudioSession.sharedInstance;
        [as setPreferredIOBufferDuration:*(const UInt32 *)data / (as.sampleRate > 0 ? as.sampleRate : 48000) error:nil];
        NotifySizeListeners(u, sc, el);
        return noErr;
    }
    // FMOD sets its client format with mSampleRate 0 ("device rate" on a HAL unit). RemoteIO takes it literally and
    // rate-converts from 0 Hz: the render callback is then asked for absurd frame counts and FMOD's mixer faults.
    AudioStreamBasicDescription fixed;
    if (p == kAudioUnitProperty_StreamFormat && data && size == sizeof fixed && ((const AudioStreamBasicDescription *)data)->mSampleRate == 0) {
        fixed = *(const AudioStreamBasicDescription *)data; fixed.mSampleRate = SessionRate(); data = &fixed;
    }
    AURenderCallbackStruct wrapped;   // counted like AUGraph callbacks (FMOD sets its mixer this way)
    if (p == kAudioUnitProperty_SetRenderCallback && data && size == sizeof wrapped && ((const AURenderCallbackStruct *)data)->inputProc) {
        const AURenderCallbackStruct *cb = data;
        Tramp *t = malloc(sizeof *t); *t = (Tramp){cb->inputProc, cb->inputProcRefCon};
        wrapped = (AURenderCallbackStruct){Counted, t}; data = &wrapped;
    }
    OSStatus s = REAL(AudioUnitSetProperty)(u, p, sc, el, data, size);
    LOG(AudioUnitSetProperty, @"(%p, %u, scope %u, el %u, %u bytes%@) -> %@", u, (unsigned)p, (unsigned)sc, (unsigned)el, (unsigned)size,
        p == kAudioUnitProperty_StreamFormat && data ? [@" " stringByAppendingString:ASBD(data)] : @"", FCC(s));
    return s;
}
OSStatus AudioUnitSetParameter(AudioUnit u, AudioUnitParameterID p, AudioUnitScope sc, AudioUnitElement el, AudioUnitParameterValue v, UInt32 off) {
    OSStatus s = REAL(AudioUnitSetParameter)(u, p, sc, el, v, off); LOG(AudioUnitSetParameter, @"(%p, %u, scope %u, el %u, %g) -> %@", u, (unsigned)p, (unsigned)sc, (unsigned)el, v, FCC(s)); return s;
}
OSStatus AudioUnitRender(AudioUnit u, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus s = REAL(AudioUnitRender)(u, flags, ts, bus, frames, io); LOG(AudioUnitRender, @"(%p, bus %u, %u frames) -> %@", u, (unsigned)bus, (unsigned)frames, FCC(s)); return s;
}
OSStatus AudioOutputUnitStart(AudioUnit u) { if (Disposed(u)) return kAudio_ParamError; OSStatus s = REAL(AudioOutputUnitStart)(u); if (!s) Track(&gUnits, u, YES); LOG(AudioOutputUnitStart, @"(%p) -> %@", u, FCC(s)); return s; }
OSStatus AudioOutputUnitStop(AudioUnit u) { if (Disposed(u)) return kAudio_ParamError; OSStatus s = REAL(AudioOutputUnitStop)(u); Track(&gUnits, u, NO); LOG(AudioOutputUnitStop, @"(%p) -> %@", u, FCC(s)); return s; }

// --- AudioConverter
OSStatus AudioConverterNew(const AudioStreamBasicDescription *src, const AudioStreamBasicDescription *dst, AudioConverterRef *out) {
    OSStatus s = REAL(AudioConverterNew)(src, dst, out); LOG(AudioConverterNew, @"(%@ -> %@) -> %@", ASBD(src), ASBD(dst), FCC(s)); return s;
}
OSStatus AudioConverterDispose(AudioConverterRef c) { OSStatus s = REAL(AudioConverterDispose)(c); LOG(AudioConverterDispose, @"(%p) -> %@", c, FCC(s)); return s; }
OSStatus AudioConverterReset(AudioConverterRef c) { OSStatus s = REAL(AudioConverterReset)(c); LOG(AudioConverterReset, @"(%p) -> %@", c, FCC(s)); return s; }
OSStatus AudioConverterFillComplexBuffer(AudioConverterRef c, AudioConverterComplexInputDataProc proc, void *user, UInt32 *ioPackets,
                                         AudioBufferList *out, AudioStreamPacketDescription *outDesc) {
    OSStatus s = REAL(AudioConverterFillComplexBuffer)(c, proc, user, ioPackets, out, outDesc);
    LOG(AudioConverterFillComplexBuffer, @"(%p) -> %@ packets=%u", c, FCC(s), ioPackets ? (unsigned)*ioPackets : 0); return s;
}

// --- AudioQueue
OSStatus AudioQueueNewOutput(const AudioStreamBasicDescription *f, AudioQueueOutputCallback cb, void *user, CFRunLoopRef rl, CFStringRef mode, UInt32 flags, AudioQueueRef *out) {
    ActivateSession();   // the queue is silent (or follows the mute switch) without the playback session
    OSStatus s = REAL(AudioQueueNewOutput)(f, cb, user, rl, mode, flags, out); LOG(AudioQueueNewOutput, @"(%@) -> %@", ASBD(f), FCC(s)); return s;
}
OSStatus AudioQueueAllocateBuffer(AudioQueueRef q, UInt32 size, AudioQueueBufferRef *out) {
    OSStatus s = REAL(AudioQueueAllocateBuffer)(q, size, out); LOG(AudioQueueAllocateBuffer, @"(%p, %u) -> %@", q, (unsigned)size, FCC(s)); return s;
}
OSStatus AudioQueueEnqueueBuffer(AudioQueueRef q, AudioQueueBufferRef b, UInt32 n, const AudioStreamPacketDescription *d) {
    OSStatus s = REAL(AudioQueueEnqueueBuffer)(q, b, n, d); LOG(AudioQueueEnqueueBuffer, @"(%p) -> %@", q, FCC(s)); return s;
}
// macOS code (SDL2's CoreAudio backend) points the queue at a HAL device by UID; ours is the shim's single device,
// which iOS does not know, so AudioQueueStart then fails with kAudioQueueErr_InvalidDevice (-66680, Mina the Hollower).
// iOS routes a queue to the session's output anyway: accept the assignment and drop it.
OSStatus AudioQueueSetProperty(AudioQueueRef q, AudioQueuePropertyID p, const void *data, UInt32 size) {
    if (p == 'aqcd') { LOG(AudioQueueSetProperty, @"(%p, CurrentDevice) -> accepted", q); return noErr; }   // kAudioQueueProperty_CurrentDevice
    OSStatus s = REAL(AudioQueueSetProperty)(q, p, data, size); LOG(AudioQueueSetProperty, @"(%p, %@) -> %@", q, FCC(p), FCC(s)); return s;
}
OSStatus AudioQueueStart(AudioQueueRef q, const AudioTimeStamp *t) { OSStatus s = REAL(AudioQueueStart)(q, t); if (!s) Track(&gQueues, q, YES); LOG(AudioQueueStart, @"(%p) -> %@", q, FCC(s)); return s; }
OSStatus AudioQueueReset(AudioQueueRef q) { OSStatus s = REAL(AudioQueueReset)(q); LOG(AudioQueueReset, @"(%p) -> %@", q, FCC(s)); return s; }
OSStatus AudioQueueDispose(AudioQueueRef q, Boolean immediate) { Track(&gQueues, q, NO); OSStatus s = REAL(AudioQueueDispose)(q, immediate); LOG(AudioQueueDispose, @"(%p) -> %@", q, FCC(s)); return s; }

// The game ended (ShackGuestEnded in the loader): stop whatever it left playing and let other apps' audio resume.
void ShackAudioStopAll(void) {
    NSArray<NSValue *> *queues, *units, *graphs;
    @synchronized(NSValue.class) { queues = gQueues.allObjects; units = gUnits.allObjects; graphs = gGraphs.allObjects;
                                   [gQueues removeAllObjects]; [gUnits removeAllObjects]; [gGraphs removeAllObjects]; }
    for (NSValue *v in queues) REAL(AudioQueueStop)((AudioQueueRef)v.pointerValue, true);
    for (NSValue *v in units) REAL(AudioOutputUnitStop)((AudioUnit)v.pointerValue);
    for (NSValue *v in graphs) REAL(AUGraphStop)((AUGraph)v.pointerValue);
    NSError *e = nil;
    BOOL off = [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&e];
    NSLog(@"[ShackAudio] game ended: stopped %lu queues, %lu units, %lu graphs; session off=%d %@",
          (unsigned long)queues.count, (unsigned long)units.count, (unsigned long)graphs.count, off, e ?: @"");
}

// The JIT helper's debugger stops the whole app for ~15 s (a game Steam started that needs JIT); whatever plays then
// (Big Picture) stutters on what is left in its buffer. Paused before, started again after: only what this paused,
// and only if its owner has neither stopped nor disposed it meanwhile (a stop by its owner untracks it).
// ponytail: output units and queues, what Steam's UI plays through; graphs are a game's, and the game has not started.
void ShackAudioPauseAll(BOOL pause) {
    static NSArray<NSValue *> *pausedUnits, *pausedQueues;
    if (pause) {
        NSArray<NSValue *> *units, *queues;
        @synchronized(NSValue.class) { units = gUnits.allObjects ?: @[]; queues = gQueues.allObjects ?: @[]; }
        NSMutableArray<NSValue *> *paused = [NSMutableArray array];
        for (NSValue *v in units) REAL(AudioOutputUnitStop)((AudioUnit)v.pointerValue);   // still tracked: not its owner's stop
        for (NSValue *v in queues) {   // a queue stays tracked until disposed: only the running ones
            UInt32 running = 0, size = sizeof running;
            AudioQueueRef q = (AudioQueueRef)v.pointerValue;
            if (!REAL(AudioQueueGetProperty)(q, kAudioQueueProperty_IsRunning, &running, &size) && running && !REAL(AudioQueuePause)(q))
                [paused addObject:v];
        }
        pausedUnits = units; pausedQueues = paused;
    } else {
        for (NSValue *v in pausedUnits) {
            BOOL live; @synchronized(NSValue.class) { live = [gUnits containsObject:v]; }
            if (live && !Disposed(v.pointerValue)) REAL(AudioOutputUnitStart)((AudioUnit)v.pointerValue);
        }
        for (NSValue *v in pausedQueues) {
            BOOL live; @synchronized(NSValue.class) { live = [gQueues containsObject:v]; }
            if (live) REAL(AudioQueueStart)((AudioQueueRef)v.pointerValue, NULL);
        }
    }
    NSLog(@"[ShackAudio] %@ %lu units, %lu queues for the JIT helper", pause ? @"paused" : @"resumed",
          (unsigned long)pausedUnits.count, (unsigned long)pausedQueues.count);
    if (!pause) pausedUnits = pausedQueues = nil;
}
