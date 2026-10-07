#pragma once
#include <signal.h>
#include <stddef.h>

// Stock (unrebuilt) Unity Mono on the dual-mapped JIT pool. Active only when SHACK_JIT_POOL is set and the loaded Mono
// is not the dual-map rebuild (which manages the pool itself).
void *ShackTrapJITAlloc(size_t len);             // an executable mmap: pool memory (RX address), or NULL = not ours
int ShackTrapJITOwns(const void *p);
int ShackTrapJITFault(siginfo_t *si, void *uc);  // 1 = a store into the pool was replayed on the RW alias
void ShackTrapJITHookMono(void);                 // rebinds libmonobdwgc's mem*/mprotect/icache imports when it loads
