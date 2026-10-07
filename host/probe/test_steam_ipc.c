// Mac check of libShackSteamClient's in-process IPC (shims/SteamClient/SteamIPC.c): this binary's own definitions win.
//   clang host/probe/test_steam_ipc.c shims/SteamClient/SteamIPC.c -o /tmp/t && /tmp/t
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

struct shack_sembuf { unsigned short sem_num; short sem_op; short sem_flg; };
int semget(int, int, int);
int semop(int, struct shack_sembuf *, size_t);
int semctl(int, int, int, ...);
void *sem_open(const char *, int, ...);
int sem_trywait(void *), sem_post(void *), sem_unlink(const char *);
int shm_open(const char *, int, ...), shm_unlink(const char *);

int main(void) {
    int id = semget(0x5754, 1, 01000 | 02000 | 0666);
    assert(id > 0 && semget(0x5754, 1, 01000 | 02000 | 0666) == -1 && errno == EEXIST);
    assert(semget(0x5754, 1, 0) == id);
    assert(semctl(id, 0, 8, 1) == 0 && semctl(id, 0, 5) == 1);                         // SETVAL, GETVAL
    struct shack_sembuf take = { 0, -1, 0 }, take_nowait = { 0, -1, 04000 }, give = { 0, 1, 0 };
    assert(semop(id, &take, 1) == 0 && semop(id, &take_nowait, 1) == -1 && errno == EAGAIN);
    assert(semop(id, &give, 1) == 0 && semctl(id, 0, 5) == 1);
    unsigned char ds[72];
    assert(semctl(id, 0, 2, ds) == 0 && *(unsigned short *)(ds + 28) == 1);            // IPC_STAT: sem_nsems
    assert(semctl(id, 0, 0) == 0 && semop(id, &give, 1) == -1 && errno == EINVAL);     // IPC_RMID

    void *s = sem_open("/steam-test", O_CREAT | O_EXCL, 0600, 0);
    assert(s != (void *)-1 && sem_open("/steam-test", O_CREAT | O_EXCL, 0600, 0) == (void *)-1 && errno == EEXIST);
    assert(sem_open("/steam-test", 0) == s);
    assert(sem_trywait(s) == -1 && errno == EAGAIN && sem_post(s) == 0 && sem_trywait(s) == 0);
    assert(sem_unlink("/steam-test") == 0 && sem_open("/steam-test", 0) == (void *)-1 && errno == ENOENT);

    int fd = shm_open("/steam-shm-test", O_CREAT | O_RDWR | O_EXCL, 0600);
    assert(fd >= 0 && ftruncate(fd, 4096) == 0);
    char *a = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    strcpy(a, "steam");
    int fd2 = shm_open("/steam-shm-test", O_RDWR);
    char *b = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd2, 0);
    assert(!strcmp(b, "steam") && shm_unlink("/steam-shm-test") == 0);
    puts("steam ipc ok");
}
