// Component Manager (Carbon, deprecated since 10.8) on AudioComponent: FMOD Ex (Shovel Knight) finds and opens its
// output unit this way. A ComponentDescription is an AudioComponentDescription field for field, and a Component /
// ComponentInstance is the AudioComponent / AudioUnit. The calls go to libShackAudioToolbox's versions, which turn a
// Mac output unit ('ahal', 'def ') into RemoteIO; iOS has no Component Manager of its own.
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>

static void *audioToolboxShim(const char *name) {
    static void *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = dlopen("@rpath/libShackAudioToolbox.dylib", RTLD_LAZY | RTLD_NOLOAD); });
    void *f = h ? dlsym(h, name) : NULL;
    return f ? f : dlsym(RTLD_DEFAULT, name);
}

void *FindNextComponent(void *after, AudioComponentDescription *desc) {
    AudioComponent (*find)(AudioComponent, const AudioComponentDescription *) = audioToolboxShim("AudioComponentFindNext");
    return find ? find((AudioComponent)after, desc) : NULL;
}
OSErr OpenAComponent(void *component, void **instance) {
    OSStatus (*open)(AudioComponent, AudioComponentInstance *) = audioToolboxShim("AudioComponentInstanceNew");
    return open ? (OSErr)open((AudioComponent)component, (AudioComponentInstance *)instance) : -2003;   // badComponentType
}
void *OpenComponent(void *component) { void *i = NULL; return OpenAComponent(component, &i) == noErr ? i : NULL; }
OSErr CloseComponent(void *instance) {
    OSStatus (*dispose)(AudioComponentInstance) = audioToolboxShim("AudioComponentInstanceDispose");
    return instance && dispose ? (OSErr)dispose((AudioComponentInstance)instance) : noErr;
}
long CountComponents(AudioComponentDescription *desc) { return (long)AudioComponentCount(desc); }
