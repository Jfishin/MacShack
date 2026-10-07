// libShackSteamClient: the programs Steam starts besides itself. iOS lets an app start no other program, so for Steam's
// images (their libSystem imports resolve here first) every way of starting one fails cleanly, which Steam tolerates
// (the Mac run with ONEHOST_NO_SPAWN, prep/steam-onehost/README.md). Its in-process stand-ins come from the host instead.
// The one answer Steam needs from a program is lsof's: which process holds a local TCP connection, asked before
// Steam trusts it (popen "/usr/sbin/lsof -F up -i TCP@127.0.0.1:<port>"; without it the UI never connects). It is
// answered here, in lsof's -F up format: this process, if one of its own TCP sockets uses the port (another app on the
// device is not vouched for), else nothing. Mac original: prep/steam-onehost/onehost.m.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <os/log.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static void refused(const char *what, const char *path) {
    os_log(OS_LOG_DEFAULT, "[SteamClient] refused, no other processes on iOS: %{public}s %{public}s", what, path ? path : "");
    fprintf(stderr, "[SteamClient] refused, no other processes on iOS: %s %s\n", what, path ? path : "");
}

pid_t fork(void) { refused("fork", ""); errno = EPERM; return -1; }
int execv(const char *path, char *const argv[]) { (void)argv; refused("execv", path); errno = EPERM; return -1; }
int execve(const char *path, char *const argv[], char *const envp[]) { (void)argv; (void)envp; refused("execve", path); errno = EPERM; return -1; }
int execvp(const char *file, char *const argv[]) { (void)argv; refused("execvp", file); errno = EPERM; return -1; }
int posix_spawn(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *restrict attr, char *const argv[restrict], char *const envp[restrict]) {
    (void)pid; (void)actions; (void)attr; (void)envp;
    refused("posix_spawn", argv && argv[0] && argv[1] && argv[2] ? argv[2] : path);   // sh -c '<command>' shows the command
    return EPERM;
}
int posix_spawnp(pid_t *restrict pid, const char *restrict file, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *restrict attr, char *const argv[restrict], char *const envp[restrict]) {
    (void)pid; (void)actions; (void)attr; (void)argv; (void)envp;
    refused("posix_spawnp", file);
    return EPERM;
}

static int ownSocketUsesPort(int port) {   // this process's own sockets, by their local or remote port
    for (int fd = 0, n = getdtablesize(); fd < n; fd++) {
        struct stat st;
        if (fstat(fd, &st) || !S_ISSOCK(st.st_mode)) continue;
        struct sockaddr_storage a;
        socklen_t len = sizeof a;
        if (!getsockname(fd, (struct sockaddr *)&a, &len) && a.ss_family == AF_INET && ntohs(((struct sockaddr_in *)&a)->sin_port) == port) return 1;
        len = sizeof a;
        if (!getpeername(fd, (struct sockaddr *)&a, &len) && a.ss_family == AF_INET && ntohs(((struct sockaddr_in *)&a)->sin_port) == port) return 1;
    }
    return 0;
}

enum { kAnswers = 16 };   // ponytail: a fixed table; Steam closes each answer right after reading it
static FILE *answers[kAnswers];
static pthread_mutex_t answersLock = PTHREAD_MUTEX_INITIALIZER;

FILE *popen(const char *command, const char *mode) {
    (void)mode;
    int port;
    if (!command || sscanf(command, "/usr/sbin/lsof -F up -i TCP@127.0.0.1:%d", &port) != 1) {
        refused("popen", command);
        errno = EPERM;
        return NULL;
    }
    char answer[64];
    int len = ownSocketUsesPort(port) ? snprintf(answer, sizeof answer, "p%d\nu%d\n", getpid(), getuid()) : 0;
    char *buffer = strdup(len ? answer : " ");
    FILE *f = fmemopen(buffer, len ? (size_t)len : 1, "r");
    if (f && !len) fgetc(f);   // an empty answer: lsof found nothing
    pthread_mutex_lock(&answersLock);
    for (int i = 0; i < kAnswers; i++) if (!answers[i]) { answers[i] = f; break; }
    pthread_mutex_unlock(&answersLock);
    return f;
}
int pclose(FILE *f) {
    pthread_mutex_lock(&answersLock);
    int ours = 0;
    for (int i = 0; i < kAnswers; i++) if (f && answers[i] == f) { answers[i] = NULL; ours = 1; }
    pthread_mutex_unlock(&answersLock);
    if (!ours) { errno = ECHILD; return -1; }
    fclose(f);
    return 0;   // lsof's exit status
}
