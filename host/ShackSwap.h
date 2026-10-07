#pragma once
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef void *(*ShackMmapFn)(void *, size_t, int, int, int, off_t);
typedef int (*ShackMunmapFn)(void *, size_t);

// Serve guest read-write anonymous mappings from a file-backed arena of up to capMB (clamped to free disk). 0 on success.
int ShackSwapInit(const char *path, uint64_t capMB, ShackMmapFn realMmap);
// mmap/munmap through the tier; `caller` is the return address (system-framework callers are left alone).
void *ShackSwapMmap(void *addr, size_t len, int prot, int flags, int fd, off_t off, void *caller, ShackMmapFn orig);
int ShackSwapMunmap(void *addr, size_t len, void *caller, ShackMunmapFn orig);
void ShackSwapStats(char *buf, size_t n);
#ifdef SHACK_SWAP_TEST
void ShackSwapTestFailPunch(int error);
#endif
