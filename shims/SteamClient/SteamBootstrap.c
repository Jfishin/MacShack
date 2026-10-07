// libShackSteamClient: Mach services and Unix socket paths for the Steam client, kept inside this one process.
// - Mach: Steam's ipcserver is a launchd agent (MachServices com.valvesoftware.steam.ipctool) through which libsteam_api
//   finds the running Steam ("SteamAPI_Init() failed; ipcserver init failed" without it); Chromium checks in a named
//   channel of its own. iOS has neither launchd agents nor global Mach services, but every client is in this process:
//   a service a Steam image checks in is kept here, and a look-up finds it here first. The first look-up of ipcserver's
//   service starts ipcserver (its prepared copy) on a thread of its own; it checks in the same port.
// - Unix sockets: Steam's Chromium channel binds /tmp/steam_chrome_shmem_uid<uid>_spid<pid>; an app cannot write /tmp.
//   Socket paths under /tmp and /var/tmp become a short name in the app's tmp (sun_path holds 104 bytes, the
//   container's tmp path alone is ~90), the same for bind and connect.
// Only Steam's images bind to these (their libSystem imports resolve through libShackSteamClient first).
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <dirent.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

// <servers/bootstrap.h> is not in the iOS SDK; libxpc exports these as on macOS.
typedef char name_t[128];
enum { BOOTSTRAP_UNKNOWN_SERVICE = 1102 };
kern_return_t bootstrap_check_in(mach_port_t bp, const name_t name, mach_port_t *port);
kern_return_t bootstrap_look_up(mach_port_t bp, const name_t name, mach_port_t *port);

// The real calls, by handle: a plain call from this library would reach its own definition.
static void *systemSymbol(const char *lib, const char *name) {
    void *h = dlopen(lib, RTLD_LAZY | RTLD_NOLOAD);
    return h ? dlsym(h, name) : NULL;
}

// --- Mach services ---

typedef struct service { char name[128]; mach_port_t port; struct service *next; } service_t;
static service_t *services;
static pthread_mutex_t servicesLock = PTHREAD_MUTEX_INITIALIZER;
static const char kIpcService[] = "com.valvesoftware.steam.ipctool";

static void *ipcServerThread(void *unused) {
    (void)unused;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Guests/SteamClient/Steam/Contents/MacOS/ipcserver", getenv("HOME"));
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    int (*entry)(int, char **, char **, char **) = NULL;
    // Its LC_MAIN, from its own header (an executable exports _mh_execute_header; image names may be remapped).
    const struct mach_header_64 *mh = h ? dlsym(h, "_mh_execute_header") : NULL;
    const struct load_command *lc = mh ? (const void *)(mh + 1) : NULL;
    for (uint32_t c = 0; mh && c < mh->ncmds; c++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_MAIN) entry = (void *)((const char *)mh + ((const struct entry_point_command *)lc)->entryoff);
    fprintf(stderr, "[SteamClient] ipcserver in-process: %s\n", entry ? "starting" : "no LC_MAIN");
    char *argv[] = { path, NULL };
    extern char **environ;
    if (entry) entry(1, argv, environ, NULL);
    return NULL;
}

// The port registered under name, created on first use (receive and send rights in this task).
static mach_port_t servicePort(const char *name, int create) {
    pthread_mutex_lock(&servicesLock);
    service_t *s = services;
    while (s && strcmp(s->name, name)) s = s->next;
    if (!s && create) {
        s = calloc(1, sizeof *s);
        strlcpy(s->name, name, sizeof s->name);
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &s->port);
        mach_port_insert_right(mach_task_self(), s->port, s->port, MACH_MSG_TYPE_MAKE_SEND);
        s->next = services;
        services = s;
        if (!strcmp(name, kIpcService)) {
            pthread_t t;
            pthread_create(&t, NULL, ipcServerThread, NULL);
            pthread_detach(t);
        }
    }
    mach_port_t port = s ? s->port : MACH_PORT_NULL;
    pthread_mutex_unlock(&servicesLock);
    return port;
}

kern_return_t bootstrap_check_in(mach_port_t bp, const name_t name, mach_port_t *port) {
    (void)bp;
    *port = servicePort(name, 1);   // every service a Steam image offers lives here: nothing outside could reach it
    return KERN_SUCCESS;
}

kern_return_t bootstrap_look_up(mach_port_t bp, const name_t name, mach_port_t *port) {
    mach_port_t p = servicePort(name, !strcmp(name, kIpcService));
    if (p != MACH_PORT_NULL) {
        mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_SEND, 1);   // the caller's own send right to release
        *port = p;
        return KERN_SUCCESS;
    }
    static kern_return_t (*real)(mach_port_t, const name_t, mach_port_t *);
    if (!real) real = systemSymbol("/usr/lib/system/libxpc.dylib", "bootstrap_look_up");
    return real ? real(bp, name, port) : BOOTSTRAP_UNKNOWN_SERVICE;
}

// --- Unix socket paths ---

static const char *socketDir(void) {
    static char dir[96];
    if (!*dir) {
        const char *tmp = getenv("TMPDIR");
        size_t n = (size_t)snprintf(dir, sizeof dir, "%s", tmp && *tmp ? tmp : "/tmp/");
        if (n && dir[n - 1] != '/') strlcat(dir, "/", sizeof dir);
        strlcat(dir, "s", sizeof dir);
        mkdir(dir, 0700);
    }
    return dir;
}
// A /tmp or /var/tmp socket path as <tmp>/s/<hash of the original>: deterministic, so bind and connect agree.
static socklen_t mapSocket(const struct sockaddr *addr, socklen_t len, struct sockaddr_un *out) {
    const struct sockaddr_un *un = (const void *)addr;
    if (!addr || addr->sa_family != AF_UNIX || (strncmp(un->sun_path, "/tmp/", 5) && strncmp(un->sun_path, "/var/tmp/", 9))) return 0;
    uint32_t hash = 2166136261u;   // FNV-1a
    for (const char *p = un->sun_path; *p && p < un->sun_path + sizeof un->sun_path; p++) hash = (hash ^ (uint8_t)*p) * 16777619u;
    memset(out, 0, sizeof *out);
    out->sun_family = AF_UNIX;
    snprintf(out->sun_path, sizeof out->sun_path, "%s/%08x", socketDir(), hash);
    out->sun_len = (uint8_t)SUN_LEN(out);
    (void)len;
    return out->sun_len;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
    static int (*real)(int, const struct sockaddr *, socklen_t);
    if (!real) real = systemSymbol("/usr/lib/system/libsystem_kernel.dylib", "bind");
    struct sockaddr_un mapped;
    socklen_t mappedLen = mapSocket(addr, len, &mapped);
    if (!mappedLen) return real(fd, addr, len);
    unlink(mapped.sun_path);   // a stale socket from an earlier run of this process
    int rc = real(fd, (const struct sockaddr *)&mapped, mappedLen), e = errno;
    fprintf(stderr, "[SteamClient] bind %s -> %s: %d %s\n", ((const struct sockaddr_un *)addr)->sun_path, mapped.sun_path, rc, rc ? strerror(e) : "");
    errno = e;
    return rc;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    static int (*real)(int, const struct sockaddr *, socklen_t);
    if (!real) real = systemSymbol("/usr/lib/system/libsystem_kernel.dylib", "connect");
    struct sockaddr_un mapped;
    socklen_t mappedLen = mapSocket(addr, len, &mapped);
    if (!mappedLen) return real(fd, addr, len);
    int rc = real(fd, (const struct sockaddr *)&mapped, mappedLen), e = errno;
    static int logged;
    if (rc || logged++ < 4) fprintf(stderr, "[SteamClient] connect %s -> %s: %d %s\n", ((const struct sockaddr_un *)addr)->sun_path, mapped.sun_path, rc, rc ? strerror(e) : "");
    errno = e;
    return rc;
}
