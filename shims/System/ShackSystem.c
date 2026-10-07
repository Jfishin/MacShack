// libSystem symbols macOS has and iOS lacks, plus small macOS-only system libraries. Re-exports libSystem, CFNetwork and
// libswiftCore; guests' load commands for those (and OpenCL, LDAP) point here.
#include <stdarg.h>
#include <syslog.h>

// macOS's syslog with the UNIX2003 extensions is plain syslog on iOS.
void shack_syslog(int priority, const char *fmt, ...) __asm__("_syslog$DARWIN_EXTSN");
void shack_syslog(int priority, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(priority, fmt, ap); va_end(ap); }

// ponytail: iOS has no per-thread MAP_JIT write toggle. JIT memory permissions are the JIT enablement layer's job;
// this no-op only lets Mono load.
void pthread_jit_write_protect_np(int enabled) {}

// @available(macOS N, *) compiles to compiler-rt's __isPlatformVersionAtLeast, which asks dyld this with
// platform 1 (PLATFORM_MACOS). dyld only answers for the running platform, so on iOS every macOS check fails and
// guests take their pre-macOS-11 fallbacks (InControlNative skips its GameController path: no gamepad). The guest
// was built for macOS 11+, so answer yes for any macOS entry; other platforms go to the real dyld function.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
typedef struct { uint32_t platform, version; } dyld_build_version_t;
int _availability_version_check(uint32_t count, dyld_build_version_t versions[]) {
    static int (*real)(uint32_t, dyld_build_version_t *); static int logged;
    if (!real) real = dlsym(dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW), "_availability_version_check");
    for (uint32_t i = 0; i < count; i++)
        if (versions[i].platform == 1) {
            if (logged++ < 20) fprintf(stderr, "[ShackSystem] @available(macOS %u.%u) -> yes\n", versions[i].version >> 16, (versions[i].version >> 8) & 0xff);
            return 1;
        }
    return real ? real(count, versions) : 1;
}

// Swift's `#available` in code built with the macOS 26 SDK calls this macOS-only libswiftCore entry (it also answers for a
// zippered Catalyst variant); iOS's libswiftCore lacks it. Same answer as above: a macOS check is yes. Guests' libswiftCore
// load commands point here (LINK_MAP) and libswiftCore is re-exported. Arguments: macOS and variant major/minor/patch.
#include <stdbool.h>
bool shack_swift_version_or_variant(intptr_t a, intptr_t b, intptr_t c, intptr_t d, intptr_t e, intptr_t f)
    __asm__("_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF");
bool shack_swift_version_or_variant(intptr_t a, intptr_t b, intptr_t c, intptr_t d, intptr_t e, intptr_t f) { return true; }

// CFNetwork keys macOS exports and iOS does not; iOS's proxy dictionaries use the same strings. CFNetwork is re-exported.
#include <CoreFoundation/CoreFoundation.h>
const CFStringRef kCFNetworkProxiesHTTPSEnable = CFSTR("HTTPSEnable");
const CFStringRef kCFNetworkProxiesHTTPSPort = CFSTR("HTTPSPort");
const CFStringRef kCFNetworkProxiesHTTPSProxy = CFSTR("HTTPSProxy");
const CFStringRef kCFNetworkProxiesExceptionsList = CFSTR("ExceptionsList");

// Total RAM, as this process can use it. On a Mac, hw.memsize is what a game may plan around; on iOS a single app gets a
// fraction of the physical RAM (~8.5 GB of 12 here), so report the app's own limit: its footprint plus what iOS says it
// may still allocate, fixed at the first query. Engines size caches and pick asset sets from it (Hades II loads its 720p
// packages below ~9000 MB instead of 3.5 GB of 1080p ones that ran it out of memory).
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <string.h>
static uint64_t AppMemoryLimit(void) {
    static uint64_t limit;
    if (!limit) {
        task_vm_info_data_t vm; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        uint64_t used = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS ? vm.phys_footprint : 0;
        limit = used + os_proc_available_memory();
    }
    return limit;
}
static void ClampMemsize(void *oldp, size_t *oldlenp) {
    if (!oldp || !oldlenp) return;
    uint64_t lim = AppMemoryLimit();
    if (*oldlenp == sizeof(uint64_t)) { uint64_t *v = oldp; if (lim && *v > lim) *v = lim; }
    else if (*oldlenp == sizeof(uint32_t)) { uint32_t *v = oldp; if (lim && *v > lim) *v = (uint32_t)lim; }
}
int sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    static int (*real)(int *, u_int, void *, size_t *, void *, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "sysctl");
    int r = real(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && namelen == 2 && name[0] == CTL_HW && (name[1] == HW_MEMSIZE || name[1] == HW_PHYSMEM)) ClampMemsize(oldp, oldlenp);
    return r;
}
int sysctlbyname(const char *nm, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    static int (*real)(const char *, void *, size_t *, void *, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "sysctlbyname");
    int r = real(nm, oldp, oldlenp, newp, newlen);
    if (r == 0 && nm && (!strcmp(nm, "hw.memsize") || !strcmp(nm, "hw.physmem"))) ClampMemsize(oldp, oldlenp);
    return r;
}

// OpenCL.framework (macOS only): no platform. Factorio only probes it for its GPU report.
typedef int32_t cl_int;
cl_int clGetPlatformIDs(uint32_t num_entries, void **platforms, uint32_t *num_platforms) {
    if (num_platforms) *num_platforms = 0;
    return -1001;   // CL_PLATFORM_NOT_FOUND_KHR, what an ICD loader answers with no driver
}
cl_int clGetDeviceIDs(void *platform, uint64_t type, uint32_t num_entries, void **devices, uint32_t *num_devices) {
    if (num_devices) *num_devices = 0;
    return -1;      // CL_DEVICE_NOT_FOUND
}
cl_int clGetDeviceInfo(void *device, uint32_t name, size_t size, void *value, size_t *size_ret) { return -33; }   // CL_INVALID_DEVICE

// LDAP.framework (macOS only), bound by libcurl's ldap:// support: every LDAP URL fails to parse or connect.
int ldap_url_parse(const char *url, void **ludpp) { if (ludpp) *ludpp = 0; return 3; }   // LDAP_URL_ERR_BADSCHEME
void *ldap_init(const char *host, int port) { return 0; }
char *ldap_err2string(int err) { return "LDAP is not available"; }
int ldap_set_option(void *ld, int option, const void *value) { return -1; }
int ldap_simple_bind_s(void *ld, const char *who, const char *passwd) { return 0x51; }   // LDAP_SERVER_DOWN
int ldap_search_s(void *ld, const char *base, int scope, const char *filter, char **attrs, int attrsonly, void **res) {
    if (res) *res = 0;
    return 0x51;
}
int ldap_unbind_s(void *ld) { return 0; }
void *ldap_first_entry(void *ld, void *chain) { return 0; }
void *ldap_next_entry(void *ld, void *entry) { return 0; }
char *ldap_get_dn(void *ld, void *entry) { return 0; }
char *ldap_first_attribute(void *ld, void *entry, void **ber) { if (ber) *ber = 0; return 0; }
char *ldap_next_attribute(void *ld, void *entry, void *ber) { return 0; }
void **ldap_get_values_len(void *ld, void *entry, const char *attr) { return 0; }
int ldap_value_free_len(void **vals) { return 0; }
int ldap_msgfree(void *msg) { return 0; }
void ldap_memfree(void *p) {}
void ber_free(void *ber, int freebuf) {}
void ldap_free_urldesc(void *ludp) {}

// libcurl (macOS's /usr/lib/libcurl.4.dylib; iOS has none), bound by Cyberpunk 2077's HTTP pool (news, rewards, crash
// upload). ponytail: every transfer fails at once with "couldn't connect", which games treat as offline; wire it to
// NSURLSession when a game needs the network. Handles are real so CURLOPT_PRIVATE and the multi DONE messages work.
#include <stdlib.h>
#include <string.h>
enum { CURLE_OK = 0, CURLE_COULDNT_CONNECT = 7, CURLM_OK = 0, CURLMSG_DONE = 1 };
enum { CURLOPT_ERRORBUFFER = 10010, CURLOPT_PRIVATE = 10103, CURLINFO_PRIVATE = 0x100015, CURLINFO_TYPEMASK = 0xf00000,
       CURLINFO_SOCKET = 0x500000 };
typedef struct { void *priv; char *errors; } ShackCurl;
typedef struct { int msg; ShackCurl *easy; union { void *whatever; int result; } data; } ShackCurlMsg;   // CURLMsg
typedef struct { ShackCurl **pending; int count, capacity; ShackCurlMsg msg; } ShackCurlMulti;
struct curl_slist { char *data; struct curl_slist *next; };

int curl_global_init_mem(long flags, void *m, void *f, void *r, void *s, void *c) { return CURLE_OK; }
void curl_global_cleanup(void) {}
ShackCurl *curl_easy_init(void) { return calloc(1, sizeof(ShackCurl)); }
void curl_easy_cleanup(ShackCurl *h) { free(h); }
int curl_easy_setopt(ShackCurl *h, int option, ...) {
    va_list ap; va_start(ap, option);
    if (h && option == CURLOPT_PRIVATE) h->priv = va_arg(ap, void *);
    if (h && option == CURLOPT_ERRORBUFFER) h->errors = va_arg(ap, char *);
    va_end(ap);
    return CURLE_OK;
}
const char *curl_easy_strerror(int code) { return code == CURLE_COULDNT_CONNECT ? "Couldn't connect to server" : "No error"; }
static int curlFail(ShackCurl *h) {
    if (h && h->errors) strcpy(h->errors, curl_easy_strerror(CURLE_COULDNT_CONNECT));
    return CURLE_COULDNT_CONNECT;
}
int curl_easy_perform(ShackCurl *h) { return curlFail(h); }
// Zero for every value (response code 0, no strings), except the handle's own CURLOPT_PRIVATE.
int curl_easy_getinfo(ShackCurl *h, int info, ...) {
    va_list ap; va_start(ap, info);
    void *out = va_arg(ap, void *);
    va_end(ap);
    if (!out) return CURLE_OK;
    if (info == CURLINFO_PRIVATE) *(void **)out = h ? h->priv : NULL;
    else if ((info & CURLINFO_TYPEMASK) == CURLINFO_SOCKET) *(int *)out = -1;   // CURL_SOCKET_BAD
    else memset(out, 0, 8);   // long, double, pointer and curl_off_t are all 8 bytes on arm64
    return CURLE_OK;
}
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *s) {
    struct curl_slist *item = calloc(1, sizeof *item);
    if (!item || !(item->data = strdup(s))) { free(item); return NULL; }
    if (!list) return item;
    struct curl_slist *last = list;
    while (last->next) last = last->next;
    last->next = item;
    return list;
}
void curl_slist_free_all(struct curl_slist *list) {
    while (list) { struct curl_slist *next = list->next; free(list->data); free(list); list = next; }
}
ShackCurlMulti *curl_multi_init(void) { return calloc(1, sizeof(ShackCurlMulti)); }
int curl_multi_cleanup(ShackCurlMulti *m) { if (m) free(m->pending); free(m); return CURLM_OK; }
int curl_multi_add_handle(ShackCurlMulti *m, ShackCurl *h) {
    if (m->count == m->capacity) {
        int capacity = m->capacity ? m->capacity * 2 : 16;
        ShackCurl **grown = realloc(m->pending, capacity * sizeof *grown);
        if (!grown) return 6;   // CURLM_OUT_OF_MEMORY
        m->pending = grown; m->capacity = capacity;
    }
    m->pending[m->count++] = h;
    return CURLM_OK;
}
int curl_multi_remove_handle(ShackCurlMulti *m, ShackCurl *h) {
    for (int i = 0; i < m->count; i++)
        if (m->pending[i] == h) { memmove(m->pending + i, m->pending + i + 1, (m->count - i - 1) * sizeof *m->pending); m->count--; break; }
    return CURLM_OK;
}
int curl_multi_perform(ShackCurlMulti *m, int *running) { if (running) *running = 0; return CURLM_OK; }   // all done at once
// One DONE message per added handle, oldest first; valid until the next call, as libcurl's.
ShackCurlMsg *curl_multi_info_read(ShackCurlMulti *m, int *left) {
    if (!m->count) { if (left) *left = 0; return NULL; }
    ShackCurl *h = m->pending[0];
    curl_multi_remove_handle(m, h);
    m->msg = (ShackCurlMsg){ .msg = CURLMSG_DONE, .easy = h, .data.result = curlFail(h) };
    if (left) *left = m->count;
    return &m->msg;
}
