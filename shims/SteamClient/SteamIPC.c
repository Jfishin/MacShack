// libShackSteamClient: in-process System V semaphores, POSIX named semaphores and POSIX shared memory for the Steam
// client. On iOS semget is a killed system call (SIGSYS: chromehtml's initializer died in tier0's CThreadSemaphore) and
// sem_open/shm_open are confined by the sandbox. Every Steam "process" (steam_osx, its helper, ipcserver, a game) lives
// in this one process, so a table here is all they need. Only Steam's images bind to these: their libSystem imports go
// through libShackSteamClient (ShackPrep's Steam link map), whose own definitions come before its re-exports.
#include <dirent.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sem.h>
#include <sys/stat.h>
#include <unistd.h>

// Which Steam image asked (logged with each shared object it opens: the client/Chromium handshake is told by them).
static const char *caller(const void *ra) {
    Dl_info info;
    if (!dladdr(ra, &info) || !info.dli_fname) return "?";
    const char *slash = strrchr(info.dli_fname, '/');
    return slash ? slash + 1 : info.dli_fname;
}
static int traceBudget = 60;   // ponytail: the first 60 opens; enough to see the start-up handshake

// --- System V semaphores: tier0 (semget(key, 1, IPC_CREAT|IPC_EXCL|0666), SETVAL, IPC_STAT, IPC_RMID, semop), steam_osx ---

enum { kIpcCreat = IPC_CREAT, kIpcExcl = IPC_EXCL, kIpcNoWait = IPC_NOWAIT, kIpcRmid = IPC_RMID, kIpcStat = IPC_STAT,
       kGetVal = GETVAL, kGetAll = GETALL, kSetVal = SETVAL, kSetAll = SETALL };
typedef struct { int used, key, nsems, mode; unsigned short *vals; } semset_t;
enum { kSets = 256 };   // ponytail: a fixed table; Steam makes a handful of semaphores
static semset_t sets[kSets];
static pthread_mutex_t semLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t semChanged = PTHREAD_COND_INITIALIZER;

int semget(key_t key, int nsems, int flags) {
    pthread_mutex_lock(&semLock);
    int id = -1, err = 0;
    for (int i = 1; i < kSets && key; i++) if (sets[i].used && sets[i].key == key) { id = i; break; }   // key 0: IPC_PRIVATE
    if (id > 0 && (flags & kIpcCreat) && (flags & kIpcExcl)) { id = -1; err = EEXIST; }
    else if (id < 0 && key && !(flags & kIpcCreat)) err = ENOENT;
    else if (id < 0) {
        for (int i = 1; i < kSets; i++) if (!sets[i].used) { id = i; break; }
        if (id < 0) err = ENOSPC;
        else sets[id] = (semset_t){ 1, key, nsems > 0 ? nsems : 1, flags & 0777, calloc(nsems > 0 ? nsems : 1, sizeof(unsigned short)) };
    }
    pthread_mutex_unlock(&semLock);
    if (id < 0) errno = err;
    return id;
}

int semop(int id, struct sembuf *ops, size_t n) {
    pthread_mutex_lock(&semLock);
    for (;;) {
        if (id <= 0 || id >= kSets || !sets[id].used) { pthread_mutex_unlock(&semLock); errno = EINVAL; return -1; }
        semset_t *s = &sets[id];
        int ready = 1, nowait = 0;
        for (size_t i = 0; i < n; i++) {
            if (ops[i].sem_num >= s->nsems) { pthread_mutex_unlock(&semLock); errno = EFBIG; return -1; }
            int v = s->vals[ops[i].sem_num], op = ops[i].sem_op;
            if ((op < 0 && v < -op) || (op == 0 && v)) { ready = 0; nowait |= ops[i].sem_flg & kIpcNoWait; }
        }
        if (ready) break;
        if (nowait) { pthread_mutex_unlock(&semLock); errno = EAGAIN; return -1; }
        pthread_cond_wait(&semChanged, &semLock);
    }
    for (size_t i = 0; i < n; i++) sets[id].vals[ops[i].sem_num] += ops[i].sem_op;
    pthread_cond_broadcast(&semChanged);
    pthread_mutex_unlock(&semLock);
    return 0;
}

int semctl(int id, int num, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    long arg = va_arg(ap, long);   // union semun arrives as one 8-byte slot (unused for IPC_RMID)
    va_end(ap);
    pthread_mutex_lock(&semLock);
    if (id <= 0 || id >= kSets || !sets[id].used || ((cmd == kGetVal || cmd == kSetVal) && (num < 0 || num >= sets[id].nsems))) {
        pthread_mutex_unlock(&semLock); errno = EINVAL; return -1;
    }
    semset_t *s = &sets[id];
    int result = 0;
    switch (cmd) {
    case kGetVal: result = s->vals[num]; break;
    case kSetVal: s->vals[num] = (unsigned short)(int)arg; pthread_cond_broadcast(&semChanged); break;
    case kGetAll: memcpy((void *)arg, s->vals, s->nsems * sizeof *s->vals); break;
    case kSetAll: memcpy(s->vals, (void *)arg, s->nsems * sizeof *s->vals); pthread_cond_broadcast(&semChanged); break;
    case kIpcRmid: free(s->vals); *s = (semset_t){0}; pthread_cond_broadcast(&semChanged); break;
    case kIpcStat: {
        struct semid_ds *ds = (void *)arg;
        memset(ds, 0, sizeof *ds);
        ds->sem_perm.uid = ds->sem_perm.cuid = getuid();
        ds->sem_perm.gid = ds->sem_perm.cgid = getgid();
        ds->sem_perm.mode = (mode_t)s->mode;
        ds->sem_perm._key = s->key;
        ds->sem_nsems = (unsigned short)s->nsems;
        break;
    }
    default: break;
    }
    pthread_mutex_unlock(&semLock);
    return result;
}

// --- POSIX named semaphores: steamclient, steamui, chromehtml, Steam Helper, ipcserver ---

typedef struct named { char name[256]; dispatch_semaphore_t sem; struct named *next; } named_t;
static named_t *namedList;
static pthread_mutex_t namedLock = PTHREAD_MUTEX_INITIALIZER;
sem_t *sem_open(const char *name, int oflag, ...) {
    unsigned value = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        (void)va_arg(ap, int);   // mode
        value = va_arg(ap, unsigned);
        va_end(ap);
    }
    pthread_mutex_lock(&namedLock);
    named_t *n = namedList;
    while (n && strcmp(n->name, name)) n = n->next;
    int err = 0;
    if (n && (oflag & O_CREAT) && (oflag & O_EXCL)) err = EEXIST;
    else if (!n && !(oflag & O_CREAT)) err = ENOENT;
    else if (!n) {   // never freed: a dispatch semaphore must not die below its initial value, and handles outlive unlink
        n = calloc(1, sizeof *n);
        strlcpy(n->name, name, sizeof n->name);
        n->sem = dispatch_semaphore_create(value);
        n->next = namedList;
        namedList = n;
    }
    pthread_mutex_unlock(&namedLock);
    if (err || traceBudget-- > 0)
        fprintf(stderr, "[SteamClient] sem_open %s (oflag 0x%x value %u) by %s: %s\n", name, oflag, value, caller(__builtin_return_address(0)), err ? strerror(err) : "ok");
    if (err) { errno = err; return SEM_FAILED; }
    return (sem_t *)n;
}
int sem_close(sem_t *sem) { (void)sem; return 0; }
int sem_unlink(const char *name) {
    pthread_mutex_lock(&namedLock);
    named_t **link = &namedList;
    while (*link && strcmp((*link)->name, name)) link = &(*link)->next;
    int found = *link != NULL;
    if (found) *link = (*link)->next;   // open handles stay valid, as after a real unlink
    pthread_mutex_unlock(&namedLock);
    if (!found) { errno = ENOENT; return -1; }
    return 0;
}
int sem_wait(sem_t *sem) { dispatch_semaphore_wait(((named_t *)sem)->sem, DISPATCH_TIME_FOREVER); return 0; }
int sem_trywait(sem_t *sem) {
    if (dispatch_semaphore_wait(((named_t *)sem)->sem, DISPATCH_TIME_NOW)) { errno = EAGAIN; return -1; }
    return 0;
}
int sem_post(sem_t *sem) { dispatch_semaphore_signal(((named_t *)sem)->sem); return 0; }

// --- POSIX shared memory: files under $TMPDIR/onehost-shm, emptied when this library loads (no other process shares them) ---

static const char *shmDir(void) {
    static char dir[1024];
    if (!*dir) {
        const char *tmp = getenv("TMPDIR");
        snprintf(dir, sizeof dir, "%s/onehost-shm", tmp && *tmp ? tmp : "/tmp");
        mkdir(dir, 0700);
    }
    return dir;
}
static void shmPath(char *out, size_t size, const char *name) {
    size_t len = (size_t)snprintf(out, size, "%s/", shmDir());
    for (const char *p = name; *p && len + 1 < size; p++) out[len++] = *p == '/' ? '_' : *p;
    out[len] = 0;
}
int shm_open(const char *name, int oflag, ...) {
    int mode = 0600;
    if (oflag & O_CREAT) { va_list ap; va_start(ap, oflag); mode = va_arg(ap, int); va_end(ap); }
    char path[1024];
    shmPath(path, sizeof path, name);
    int fd = open(path, oflag, mode), e = errno;
    if (fd < 0 || traceBudget-- > 0)
        fprintf(stderr, "[SteamClient] shm_open %s (oflag 0x%x) by %s: %s\n", name, oflag, caller(__builtin_return_address(0)), fd < 0 ? strerror(e) : "ok");
    errno = e;
    return fd;
}
int shm_unlink(const char *name) {
    char path[1024];
    shmPath(path, sizeof path, name);
    return unlink(path);
}
__attribute__((constructor)) static void clearStaleShm(void) {
    DIR *d = opendir(shmDir());
    for (struct dirent *e; d && (e = readdir(d));) {
        if (e->d_name[0] == '.') continue;
        char path[1280];
        snprintf(path, sizeof path, "%s/%s", shmDir(), e->d_name);
        unlink(path);
    }
    if (d) closedir(d);
}
