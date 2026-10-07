// Mac check of libShackSteamClient's pthread keys (shims/SteamClient/SteamTSD.c): this binary's own definitions win.
//   clang host/probe/test_steam_tsd.c shims/SteamClient/SteamTSD.c -o /tmp/t && /tmp/t
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

enum { kMany = 700 };   // more than a process's 512 real keys
static pthread_key_t keys[kMany];
static _Atomic int destroyed;
static void count(void *value) { assert(value == (void *)0x1234); destroyed++; }

static void *worker(void *unused) {
    (void)unused;
    for (int i = 0; i < kMany; i++) assert(pthread_getspecific(keys[i]) == NULL);   // a new thread starts empty
    for (int i = 0; i < kMany; i++) assert(pthread_setspecific(keys[i], (void *)0x1234) == 0);
    for (int i = 0; i < kMany; i++) assert(pthread_getspecific(keys[i]) == (void *)0x1234);
    return NULL;   // thread exit runs every key's destructor
}

int main(void) {
    for (int i = 0; i < kMany; i++) assert(pthread_key_create(&keys[i], count) == 0);
    for (int i = 0; i < kMany; i++) assert(pthread_setspecific(keys[i], (void *)(long)(i + 1)) == 0);
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    pthread_join(t, NULL);
    assert(destroyed == kMany);
    for (int i = 0; i < kMany; i++) assert(pthread_getspecific(keys[i]) == (void *)(long)(i + 1));   // untouched here
    assert(pthread_key_delete(keys[0]) == 0);
    // A real key (made by libpthread itself) passes through.
    int (*realCreate)(pthread_key_t *, void (*)(void *)) = dlsym(dlopen("/usr/lib/system/libsystem_pthread.dylib", RTLD_LAZY), "pthread_key_create");
    pthread_key_t real;
    assert(realCreate(&real, NULL) == 0 && pthread_setspecific(real, (void *)7) == 0 && pthread_getspecific(real) == (void *)7);
    puts("steam tsd ok");
    return 0;
}
