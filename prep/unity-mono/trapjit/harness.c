// Mac harness for host/ShackTrapJIT.c: dual-mapped pool as SHACK_JIT_POOL, mmap interposed like shack_mmap,
// SIGBUS/SIGSEGV kept first like shack_fault. DYLD_INSERT_LIBRARIES.
#include "ShackTrapJIT.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
static struct sigaction guest[NSIG];
static void fault(int sig, siginfo_t *si, void *uc) {
    if (ShackTrapJITFault(si, uc)) return;
    if (guest[sig].sa_flags & SA_SIGINFO) guest[sig].sa_sigaction(sig, si, uc); else signal(sig, SIG_DFL);
}
int h_sigaction(int sig, const struct sigaction *a, struct sigaction *o) {
    if (sig != SIGBUS && sig != SIGSEGV) return sigaction(sig, a, o);
    struct sigaction p = guest[sig]; if (a) guest[sig] = *a; if (o) *o = p; return 0;
}
void *h_mmap(void *a, size_t l, int p, int f, int fd, off_t o) {
    void *pool = (p & PROT_EXEC) && fd == -1 ? ShackTrapJITAlloc(l) : NULL;
    if (pool) return pool;
    return mmap(a, l, p & ~PROT_EXEC, f & ~MAP_JIT, fd, o);
}
int h_munmap(void *a, size_t l) { return ShackTrapJITOwns(a) ? 0 : munmap(a, l); }
__attribute__((constructor)) static void init(void) {
    size_t size = 256 << 20;
    void *w = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    vm_address_t x = 0; vm_prot_t cur, max;
    vm_remap(mach_task_self(), &x, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)w, FALSE, &cur, &max, VM_INHERIT_NONE);
    vm_protect(mach_task_self(), x, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    char v[80]; snprintf(v, sizeof v, "%llx,%llx,%zx", (unsigned long long)x, (unsigned long long)w, size); setenv("SHACK_JIT_POOL", v, 1);
    struct sigaction sa = {0}; sa.sa_sigaction = fault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    ShackTrapJITHookMono();
}
__attribute__((used, section("__DATA,__interpose"))) static void *ip[] = {
    (void *)h_mmap, (void *)mmap, (void *)h_munmap, (void *)munmap, (void *)h_sigaction, (void *)sigaction };
