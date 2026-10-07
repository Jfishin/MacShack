// libShackSteamClient: pthread keys for the Steam client's images, kept here on one real key. iOS gives a process 512
// keys; Steam, its Chromium and their private copies (tier0, vstdlib, steamclient x3) held ~460, so a game Steam
// started had 48 left and Okko's libGalaxy (Boost.Asio: a key per thread-local) threw "tss" from its static
// initializers (2026-10-03). On a Mac they are separate processes; here Steam's keys come from this table and the
// game keeps the process's own. Only Steam's images bind to these (their libSystem imports resolve here first).
// Keys from this table are kBase + index; any other key (made by the real call) is passed through.
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

enum { kKeys = 2048 };   // one 16 KB page of slots per thread
// The slots come from vm_allocate, never malloc: Chromium's PartitionAlloc is malloc here, and its thread cache sets a
// key of its own, so a calloc in pthread_setspecific recursed until the stack ran out (phone, 10-03).
static const pthread_key_t kBase = 0x10000;   // above every real key (iOS: fewer than 1024)
static void (*destructors[kKeys])(void *);
static _Atomic int used;   // ponytail: indices are never reused (a deleted key's stale values could resurface); 2048 is plenty

static int (*realCreate)(pthread_key_t *, void (*)(void *));
static int (*realDelete)(pthread_key_t);
static void *(*realGet)(pthread_key_t);
static int (*realSet)(pthread_key_t, const void *);
static pthread_key_t tableKey;   // this thread's slots
static pthread_once_t setup = PTHREAD_ONCE_INIT;

// At thread exit: every slot's destructor, again while one sets a value (PTHREAD_DESTRUCTOR_ITERATIONS, as pthreads).
static void endThread(void *table) {
    void **slots = table;
    realSet(tableKey, slots);   // destructors may read and set other slots
    for (int round = 0; round < PTHREAD_DESTRUCTOR_ITERATIONS; round++) {
        int again = 0;
        for (int i = 0; i < used; i++) {
            void *value = slots[i];
            if (!value || !destructors[i]) continue;
            slots[i] = NULL;
            destructors[i](value);
            again = 1;
        }
        if (!again) break;
    }
    realSet(tableKey, NULL);
    vm_deallocate(mach_task_self(), (vm_address_t)slots, kKeys * sizeof *slots);
}

static void init(void) {
    void *lib = dlopen("/usr/lib/system/libsystem_pthread.dylib", RTLD_LAZY | RTLD_NOLOAD);
    realCreate = dlsym(lib, "pthread_key_create");
    realDelete = dlsym(lib, "pthread_key_delete");
    realGet = dlsym(lib, "pthread_getspecific");
    realSet = dlsym(lib, "pthread_setspecific");
    realCreate(&tableKey, endThread);
}

int pthread_key_create(pthread_key_t *key, void (*destructor)(void *)) {
    pthread_once(&setup, init);
    int i = atomic_fetch_add(&used, 1);
    if (i >= kKeys) { atomic_fetch_sub(&used, 1); return realCreate(key, destructor); }   // table full: a real one
    destructors[i] = destructor;
    *key = kBase + (pthread_key_t)i;
    return 0;
}

int pthread_key_delete(pthread_key_t key) {
    pthread_once(&setup, init);
    if (key < kBase) return realDelete(key);
    if (key >= kBase + kKeys) return EINVAL;
    destructors[key - kBase] = NULL;   // values stay unreachable: the index is not handed out again
    return 0;
}

void *pthread_getspecific(pthread_key_t key) {
    if (!realGet) pthread_once(&setup, init);
    if (key < kBase) return realGet(key);
    void **slots = realGet(tableKey);
    return slots && key < kBase + kKeys ? slots[key - kBase] : NULL;
}

int pthread_setspecific(pthread_key_t key, const void *value) {
    pthread_once(&setup, init);
    if (key < kBase) return realSet(key, value);
    if (key >= kBase + kKeys) return EINVAL;
    void **slots = realGet(tableKey);
    if (!slots) {
        if (!value) return 0;
        vm_address_t page = 0;   // zero-filled
        if (vm_allocate(mach_task_self(), &page, kKeys * sizeof *slots, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return ENOMEM;
        realSet(tableKey, slots = (void **)page);
    }
    slots[key - kBase] = (void *)value;
    return 0;
}
