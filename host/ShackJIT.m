#import "ShackJIT.h"
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/mman.h>
#import <pthread.h>
#import <unistd.h>
#import <signal.h>
#import <setjmp.h>
#import <string.h>
#import <libkern/OSCacheControl.h>
#import <time.h>

// StikDebug JIT26 brk protocol (upstream StikJIT's INTEGRATION.md / Madeira, reimplemented here):
//   brk #0xf00d with x16 = command. x16=1 -> JIT26PrepareRegion(x0=addr|0, x1=len)
//   returns prepared RX addr in x0 (if x0==0 the debugger allocates and returns it).
//   x16=0 -> JIT26Detach. Regions prepared AFTER detach are impossible.
// On TXM only pages the attached debugger writes to become executable; mmap(MAP_JIT)/
// mprotect(PROT_EXEC) do not yield exec pages on their own.

#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
// <pthread.h> marks this unavailable on iOS; alias straight to the libsystem symbol. Weak: MacShack binds ShackSystem's
// no-op, MacShack Play links no ShackSystem and may not find it at all (then NULL, and the `--jit-spike` probe skips it).
extern void jit_wp(int enabled) __asm__("_pthread_jit_write_protect_np") __attribute__((weak_import));

#define JIT_PAGE 0x4000          // iOS 16 KB pages
// mov w0,#42 ; ret   -> the caller reads w0 as the return value
static const uint8_t CODE_42[8] = { 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 };
// mov w0,#99 ; ret   -> a distinct value so an in-place rewrite is provably observed
static const uint8_t CODE_99[8] = { 0x60, 0x0C, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 };

// ---- logging -------------------------------------------------------------
static FILE *g_log;
static void jlog(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    NSLog(@"[JITSpike] %s", buf);
    if (g_log) { fprintf(g_log, "%s\n", buf); fflush(g_log); }
}

// ---- fault guard: survive a bad execute/write to reach the summary --------
static _Thread_local sigjmp_buf g_jmp;
static _Thread_local volatile sig_atomic_t g_guarding;
static _Thread_local volatile sig_atomic_t g_missed_protocol;
static void fault_handler(int sig, siginfo_t *info, void *ctx) {
    (void)info; (void)ctx;
    if (g_guarding) { g_guarding = 0; siglongjmp(g_jmp, sig); }
    signal(sig, SIG_DFL);   // not guarding: let the real fault kill us
}
// Run `block`; sets `fault` to the signal number on fault, 0 on clean return.
// Result vars written in the block must be volatile (setjmp clobber rule).
#define GUARDED(fault, block) do { \
    int _s = sigsetjmp(g_jmp, 1); \
    if (_s == 0) { g_guarding = 1; block; g_guarding = 0; (fault) = 0; } \
    else { g_guarding = 0; (fault) = _s; } \
} while (0)

// ---- brk protocol --------------------------------------------------------
// SIGTRAP without a debugger would kill us; the handler skips the brk (pc+=4)
// and zeroes x0 so PrepareRegion "returns" 0. When StikDebug is attached the
// Mach exception is caught by the debugger before it ever becomes a signal.
static void sigtrap_handler(int sig, siginfo_t *info, void *ctx) {
    (void)sig; (void)info;
    ucontext_t *uc = (ucontext_t *)ctx;
    if (*(const uint32_t *)uc->uc_mcontext->__ss.__pc != 0xd43e01a0 ||
        uc->uc_mcontext->__ss.__x[16] > 1) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    g_missed_protocol++;
    uc->uc_mcontext->__ss.__pc += 4;
    uc->uc_mcontext->__ss.__x[0] = 0;
}

__attribute__((noinline, optnone))
static void *jit_prepare(void *addr, size_t len) {
    register void *x0 __asm__("x0") = addr;
    register size_t x1 __asm__("x1") = len;
    __asm__ volatile("mov x16, #1\n\tbrk #0xf00d\n" : "+r"(x0) : "r"(x1) : "x16", "memory");
    return x0;
}
__attribute__((noinline, optnone))
static void jit_detach(void) {
    __asm__ volatile("mov x16, #0\n\tbrk #0xf00d\n" ::: "x16", "memory");
}

typedef int (*fn_t)(void);

// Execute at `p`, guarded. Returns the value in *out and whether it ran clean.
static const char *run_at(void *p, int expect, int *out) {
    volatile int r = -1; int fault;
    fn_t f = (fn_t)p;
    GUARDED(fault, { r = f(); });
    *out = r;
    if (fault) return "fault";
    return (r == expect) ? "ok" : "wrongval";
}

static int page_protection(const char *tag, void *ptr) {
    vm_address_t address = (vm_address_t)ptr;
    vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    kern_return_t kr = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                           (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS || address > (vm_address_t)ptr) {
        jlog("%s: region query failed kr=%d", tag, kr);
        return -1;
    }
    jlog("%s: addr=%p prot=0x%x max=0x%x", tag, ptr, info.protection, info.max_protection);
    return info.protection;
}

static const char *rewrite_probe(void) {
    BOOL debuggerAllocated = [NSProcessInfo.processInfo.arguments containsObject:@"--jit-debugger-alloc"];
    uint8_t *page = debuggerAllocated ? jit_prepare(NULL, JIT_PAGE) :
        mmap(NULL, JIT_PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    jlog("E. allocation=%s addr=%p", debuggerAllocated ? "debugger" : "mmap", page);
    if (!page || page == MAP_FAILED) { jlog("E. allocation failed errno=%d", errno); return "mapfail"; }
    const char *result = "skip";
    uint8_t *code = page + 64, *neighbor = page + 128;
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int completed = 0;
    for (int round = 0; round < 20; round++) {
        int rc = mprotect(page, JIT_PAGE, PROT_READ | PROT_WRITE);
        jlog("E.%d mprotect(RW) rc=%d errno=%d", round, rc, rc ? errno : 0);
        int prot = page_protection("E.RW", page);
        if (rc || prot < 0 || !(prot & PROT_WRITE)) { result = "rwfail"; break; }
        const uint8_t *bytes = (round & 1) ? CODE_99 : CODE_42;
        int fault;
        GUARDED(fault, {
            page[0] = 0x40;
            memcpy(code, bytes, sizeof CODE_42);
            if (round == 0) memcpy(neighbor, CODE_42, sizeof CODE_42);
        });
        if (fault) { result = "writefault"; break; }
        jlog("E.%d preparing %p (code at +64, neighbor at +128)", round, page);
        void *prepared = jit_prepare(page, JIT_PAGE);
        if (prepared != page || g_missed_protocol) { result = "preparefail"; break; }
        jlog("E.%d page[0]=0x%02x (expected 0x40)", round, page[0]);
        if (page[0] != 0x40 || memcmp(code, bytes, sizeof CODE_42) ||
            memcmp(neighbor, CODE_42, sizeof CODE_42)) { result = "corrupted"; break; }
        rc = mprotect(page, JIT_PAGE, PROT_READ | PROT_EXEC);
        jlog("E.%d mprotect(RX) rc=%d errno=%d", round, rc, rc ? errno : 0);
        prot = page_protection("E.RX", page);
        if (rc || prot < 0 || !(prot & PROT_EXEC)) { result = "rxfail"; break; }
        sys_icache_invalidate(page, JIT_PAGE);
        int value;
        result = run_at(code, (round & 1) ? 99 : 42, &value);
        jlog("E.%d exec -> %d (%s)", round, value, result);
        if (strcmp(result, "ok")) break;
        result = run_at(neighbor, 42, &value);
        jlog("E.%d neighbor -> %d (%s)", round, value, result);
        if (strcmp(result, "ok")) break;
        completed++;
    }
    double elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6;
    jlog("E=%s rounds=%d/20 elapsed=%.2fms mean=%.2fms (serial probe, not Mono thread-safety proof)",
         result, completed, elapsed, completed ? elapsed / completed : 0);
    munmap(page, JIT_PAGE);
    return result;
}

static const char *alias_probe(BOOL *detached) {
    void *rx = jit_prepare(NULL, JIT_PAGE);
    jlog("C-repeat. debugger RX=%p", rx);
    if (!rx || g_missed_protocol) return "preparefail";
    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, JIT_PAGE, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    const char *result = "remapfail";
    int completed = 0;
    jlog("C-repeat. remap kr=%d alias=%p cur=0x%x max=0x%x", kr, (void *)rw, cur, max);
    if (kr == KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), rw, JIT_PAGE, FALSE, VM_PROT_READ | VM_PROT_WRITE);
        int rwProt = page_protection("C-repeat.RW", (void *)rw);
        int rxProt = page_protection("C-repeat.RX", rx);
        result = "protectfail";
        if (kr == KERN_SUCCESS && rwProt == (PROT_READ | PROT_WRITE) && rxProt == (PROT_READ | PROT_EXEC)) {
            for (int round = 0; round < 20; round++) {
                if (round == 10) {
                    jit_detach();
                    if (g_missed_protocol) { result = "detachfail"; break; }
                    *detached = YES;
                    jlog("C-repeat. detached after 10 rounds; rewriting alias again");
                }
                const uint8_t *bytes = (round & 1) ? CODE_99 : CODE_42;
                int fault;
                GUARDED(fault, { memcpy((void *)rw, bytes, sizeof CODE_42); });
                if (fault) { result = "writefault"; break; }
                if (memcmp(rx, bytes, sizeof CODE_42)) { result = "incoherent"; break; }
                sys_dcache_flush((void *)rw, sizeof CODE_42);
                sys_icache_invalidate(rx, sizeof CODE_42);
                int value;
                result = run_at(rx, (round & 1) ? 99 : 42, &value);
                jlog("C-repeat.%d exec -> %d (%s), detached=%d", round, value, result, *detached);
                if (strcmp(result, "ok")) break;
                completed++;
            }
        }
        vm_deallocate(mach_task_self(), rw, JIT_PAGE);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)rx, JIT_PAGE);
    jlog("C-repeat=%s rounds=%d/20 detached=%d", result, completed, *detached);
    return result;
}

// ---- JIT pool for a Mono guest ------------------------------------------
// One debugger-prepared RX region plus a vm_remap RW alias (the model that passed 20/20 rewrites,
// 10 of them after detach). The patched Unity Mono (mono-codeman.c) reads SHACK_JIT_POOL="rx,rw,size"
// and writes code through rw while executing and relocating against rx.
BOOL ShackJITPoolSetup(size_t bytes) { return ShackJITPoolSetupAvoiding(bytes, 0, 0); }

BOOL ShackJITPoolSetupAvoiding(size_t bytes, uintptr_t avoid, size_t avoidLength) {
    unsetenv("SHACK_JIT_POOL");
    if (bytes < (16u << 20) || bytes > (1024u << 20) || bytes % JIT_PAGE) return NO;   // macshack-jit.js prepares <= 1 GB
    uint32_t flags = 0; csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags);
    for (int i = 0; i < 360 && !(flags & CS_DEBUGGED); i++) {   // 180 s: after a reboot the helper first downloads + mounts the DDI
        usleep(500 * 1000); flags = 0; csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags);
    }
    // fprintf, not NSLog: the NSLog from this queue never reached the game log on device (2026-09-25).
    if (!(flags & CS_DEBUGGED)) { fprintf(stderr, "[ShackJIT] pool: no debugger within 180 s (csops=0x%x); Mono gets no executable memory\n", flags); return NO; }
    struct sigaction sa, oldTrap; memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_SIGINFO; sa.sa_sigaction = sigtrap_handler;
    sigaction(SIGTRAP, &sa, &oldTrap);
    g_missed_protocol = 0;
    vm_address_t held = avoid;
    kern_return_t hold = avoidLength ? vm_allocate(mach_task_self(), &held, avoidLength, VM_FLAGS_FIXED) : KERN_FAILURE;
    void *rx = jit_prepare(NULL, bytes);
    if (hold == KERN_SUCCESS) vm_deallocate(mach_task_self(), held, avoidLength);
    vm_address_t rw = 0; vm_prot_t cur = 0, max = 0; kern_return_t kr = KERN_FAILURE;
    if (rx && !g_missed_protocol) {
        kr = vm_remap(mach_task_self(), &rw, bytes, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr == KERN_SUCCESS) kr = vm_protect(mach_task_self(), rw, bytes, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    }
    BOOL ok = rx && !g_missed_protocol && kr == KERN_SUCCESS &&
              page_protection("pool.RX", rx) == (PROT_READ | PROT_EXEC) &&
              page_protection("pool.RW", (void *)rw) == (PROT_READ | PROT_WRITE);
    if (ok) {
        char v[80]; snprintf(v, sizeof v, "%llx,%llx,%zx", (unsigned long long)(uintptr_t)rx, (unsigned long long)rw, bytes);
        setenv("SHACK_JIT_POOL", v, 1);
    }
    if (!g_missed_protocol) jit_detach();
    sigaction(SIGTRAP, &oldTrap, NULL);
    fprintf(stderr, "[ShackJIT] pool %s: rx=%p rw=%p size=%zu kr=%d protocol-misses=%d csops=0x%x\n", ok ? "ready" : "FAILED",
            rx, (void *)rw, bytes, kr, g_missed_protocol, flags);
    return ok;
}

// -------------------------------------------------------------------------
void ShackJITSpike(void) {
    static BOOL ran = NO;
    if (ran) return; ran = YES;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *logs = [docs stringByAppendingPathComponent:@"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
    g_log = fopen([logs stringByAppendingPathComponent:@"jit-spike.log"].fileSystemRepresentation, "w");
    jlog("=== ShackJIT spike start (pid=%d, page=0x%x) ===", getpid(), JIT_PAGE);

    // 1. Wait for CS_DEBUGGED (StikDebug is triggered by the controller meanwhile).
    uint32_t flags = 0; csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags);
    jlog("1. csops flags=0x%x CS_DEBUGGED=%s", flags, (flags & CS_DEBUGGED) ? "SET" : "clear");
    if (!(flags & CS_DEBUGGED)) {
        jlog("1. polling up to 90s for CS_DEBUGGED...");
        BOOL got = NO;
        for (int i = 0; i < 180; i++) {          // 180 * 500ms = 90s
            usleep(500 * 1000);
            flags = 0; csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags);
            if (flags & CS_DEBUGGED) { jlog("1. CS_DEBUGGED set after %.1fs", (i + 1) * 0.5); got = YES; break; }
        }
        if (!got) jlog("1. GAVE UP: CS_DEBUGGED never set (StikDebug did not attach). No tests will run.");
    }
    BOOL debugged = (flags & CS_DEBUGGED) != 0;
    if (!debugged) {
        jlog("ABORT: no debugger observed; no executable-memory tests attempted");
        if (g_log) { fclose(g_log); g_log = NULL; }
        return;
    }

    // 2. Install SIGTRAP + fault handlers.
    struct sigaction oldTrap, oldSegv, oldBus, oldIll;
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_SIGINFO; sa.sa_sigaction = sigtrap_handler;
    sigaction(SIGTRAP, &sa, &oldTrap);
    memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_SIGINFO; sa.sa_sigaction = fault_handler;
    sigaction(SIGSEGV, &sa, &oldSegv); sigaction(SIGBUS, &sa, &oldBus); sigaction(SIGILL, &sa, &oldIll);
    jlog("2. handlers installed (SIGTRAP skip, SIGSEGV/BUS/ILL guard)");
    BOOL rewrite = [NSProcessInfo.processInfo.arguments containsObject:@"--jit-rewrite"];
    if (rewrite || [NSProcessInfo.processInfo.arguments containsObject:@"--jit-alias"]) {
        jlog("Focused probe: use macshack-jit.js; stock prepare overwrites page-leading bytes");
        BOOL detached = NO;
        const char *result = rewrite ? rewrite_probe() : alias_probe(&detached);
        if (!detached && !g_missed_protocol) jit_detach();
        jlog("%s summary=%s protocol-misses=%d", rewrite ? "E" : "C-repeat", result, g_missed_protocol);
        sigaction(SIGTRAP, &oldTrap, NULL); sigaction(SIGSEGV, &oldSegv, NULL);
        sigaction(SIGBUS, &oldBus, NULL); sigaction(SIGILL, &oldIll, NULL);
        if (g_log) { fclose(g_log); g_log = NULL; }
        return;
    }

    mach_port_t task = mach_task_self();
    const char *rA = "skip", *rB = "skip", *rC = "skip";
    const char *rDin = "skip", *rDmp = "skip", *rD2 = "skip";
    int v;

    // ---- Test A: baseline MAP_JIT + per-thread write toggle (expect fault on TXM)
    void *jitA = mmap(NULL, 1 << 20, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (jitA == MAP_FAILED) { jlog("A. mmap(MAP_JIT) FAILED errno=%d", errno); rA = "mapfail"; jitA = NULL; }
    else {
        jlog("A. MAP_JIT region at %p", jitA);
        int wf;
        GUARDED(wf, {
            if (jit_wp) jit_wp(0);
            memcpy(jitA, CODE_42, sizeof CODE_42);
            if (jit_wp) jit_wp(1);
        });
        if (wf) { jlog("A. write faulted (sig=%d)", wf); rA = "writefault"; }
        else {
            sys_icache_invalidate(jitA, sizeof CODE_42);
            rA = run_at(jitA, 42, &v);
            jlog("A. exec -> %d (%s)", v, rA);
        }
    }

    // ---- Test B: write RW anon (no MAP_JIT) BEFORE prepare, then execute in place
    void *bufB = mmap(NULL, JIT_PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (bufB == MAP_FAILED) { jlog("B. mmap FAILED errno=%d", errno); rB = "mapfail"; }
    else {
        void *codeB = (uint8_t *)bufB + 64;
        *(uint8_t *)bufB = 0x40;
        memcpy(codeB, CODE_42, sizeof CODE_42);
        void *prep = jit_prepare(bufB, JIT_PAGE);
        jlog("B. wrote code at +64, prepare(%p,0x%x) -> %p; page[0]=0x%02x (was 0x40)",
             bufB, JIT_PAGE, prep, *(uint8_t *)bufB);
        if (prep != bufB || g_missed_protocol) rB = "preparefail";
        else if (memcmp(codeB, CODE_42, sizeof CODE_42)) rB = "corrupted";
        else {
            int rc = mprotect(bufB, JIT_PAGE, PROT_READ | PROT_EXEC);
            jlog("B. mprotect(RX) rc=%d errno=%d", rc, rc ? errno : 0);
            int prot = page_protection("B.RX", bufB);
            if (rc || prot < 0 || !(prot & PROT_EXEC)) rB = "rxfail";
            else {
                sys_icache_invalidate(codeB, sizeof CODE_42);
                rB = run_at(codeB, 42, &v);
                jlog("B. exec at write addr -> %d (%s)", v, rB);
            }
        }
        munmap(bufB, JIT_PAGE);
    }

    // ---- Test C: Madeira model — debugger-allocated RX + vm_remap RW alias
    void *rxC = jit_prepare(NULL, 16 << 20);   // x0=0: debugger allocates RX, returns addr
    jlog("C. prepare(0,16MB) -> RX %p", rxC);
    if (!rxC) { jlog("C. no RX from debugger (not attached?)"); rC = "noRX"; }
    else {
        vm_address_t alias = 0; vm_prot_t cur = 0, mx = 0;
        kern_return_t kr = vm_remap(task, &alias, JIT_PAGE, 0, VM_FLAGS_ANYWHERE,
                                    task, (vm_address_t)rxC, FALSE, &cur, &mx, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) { jlog("C. vm_remap FAILED kr=%d", kr); rC = "remapfail"; }
        else {
            jlog("C. vm_remap alias=%p cur=0x%x max=0x%x", (void *)alias, cur, mx);
            kr = vm_protect(task, alias, JIT_PAGE, FALSE, VM_PROT_READ | VM_PROT_WRITE);
            jlog("C. vm_protect(alias,RW) kr=%d", kr);
            int wf;
            GUARDED(wf, { memcpy((void *)alias, CODE_42, sizeof CODE_42); });
            if (wf) { jlog("C. write via alias faulted (sig=%d)", wf); rC = "writefault"; }
            else {
                uint32_t rb = *(volatile uint32_t *)rxC;
                jlog("C. coherence: wrote 0x%x via alias, RX reads 0x%x %s",
                     *(uint32_t *)CODE_42, rb, rb == *(uint32_t *)CODE_42 ? "(OK)" : "(MISMATCH)");
                sys_icache_invalidate(rxC, sizeof CODE_42);
                rC = run_at(rxC, 42, &v);
                jlog("C. exec at RX -> %d (%s)", v, rC);
            }

            // ---- Test D: the Mono question — same-address write+exec on the C region
            // D-inplace: per-thread write toggle at the RX address directly.
            if (rC[0] == 'o') {   // only meaningful if C produced a working RX region
                int f1;
                GUARDED(f1, {
                    if (jit_wp) jit_wp(0);
                    memcpy(rxC, CODE_99, sizeof CODE_99);
                    if (jit_wp) jit_wp(1);
                });
                if (f1) { jlog("D-inplace. write faulted (sig=%d)", f1); rDin = "writefault"; }
                else {
                    sys_icache_invalidate(rxC, sizeof CODE_99);
                    rDin = run_at(rxC, 99, &v);
                    jlog("D-inplace. rewrote to 99, exec -> %d (%s)", v, rDin);
                }

                // D-mprotect: mprotect RW, write, mprotect back RX, execute.
                void *pg = (void *)((uintptr_t)rxC & ~(uintptr_t)(JIT_PAGE - 1));
                int mp1 = mprotect(pg, JIT_PAGE, PROT_READ | PROT_WRITE); int e1 = errno;
                jlog("D-mprotect. mprotect(RW) rc=%d errno=%d", mp1, mp1 ? e1 : 0);
                if (mp1) rDmp = "mprotfail";
                else {
                    int wf;
                    GUARDED(wf, { memcpy(rxC, CODE_42, sizeof CODE_42); });
                    int mp2 = mprotect(pg, JIT_PAGE, PROT_READ | PROT_EXEC);
                    jlog("D-mprotect. write %s, mprotect(RX) rc=%d errno=%d",
                         wf ? "faulted" : "ok", mp2, mp2 ? errno : 0);
                    if (wf) rDmp = "writefault";
                    else if (mp2) rDmp = "mprotfail";
                    else { sys_icache_invalidate(rxC, sizeof CODE_42); rDmp = run_at(rxC, 42, &v);
                           jlog("D-mprotect. exec -> %d (%s)", v, rDmp); }
                }
            } else { rDin = "skip"; rDmp = "skip"; }
        }
    }

    // ---- Test D2: a MAP_JIT region (from A) that is then PrepareRegion'd.
    // Does the per-thread toggle allow in-place writes AND exec afterwards?
    if (jitA) {
        void *prep = jit_prepare(jitA, 1 << 20);
        jlog("D2. prepare(MAP_JIT %p,1MB) -> %p", jitA, prep);
        int wf;
        GUARDED(wf, {
            if (jit_wp) jit_wp(0);
            memcpy(jitA, CODE_99, sizeof CODE_99);
            if (jit_wp) jit_wp(1);
        });
        if (wf) { jlog("D2. write faulted (sig=%d)", wf); rD2 = "writefault"; }
        else {
            sys_icache_invalidate(jitA, sizeof CODE_99);
            rD2 = run_at(jitA, 99, &v);
            jlog("D2. exec -> %d (%s)", v, rD2);
        }
        munmap(jitA, 1 << 20);
    } else rD2 = "noregion";

    // 6. Detach, then summary. Regions prepared after this are impossible.
    if (debugged && !g_missed_protocol) { jit_detach(); jlog("6. detach returned (protocol-misses=%d)", g_missed_protocol); }
    else jlog("6. skip detach (protocol unavailable)");

    jlog("A=%s B=%s C=%s D-inplace=%s D-mprotect=%s D2=%s protocol-misses=%d", rA, rB, rC, rDin, rDmp, rD2, g_missed_protocol);
    sigaction(SIGTRAP, &oldTrap, NULL); sigaction(SIGSEGV, &oldSegv, NULL);
    sigaction(SIGBUS, &oldBus, NULL); sigaction(SIGILL, &oldIll, NULL);
    if (g_log) { fclose(g_log); g_log = NULL; }
}

NSString *ShackJITCheck(size_t mb) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    if (!ShackJITPoolSetup(mb << 20)) return [NSString stringWithFormat:@"JIT: no pool after %.0f s\n", CFAbsoluteTimeGetCurrent() - start];
    unsigned long long rx = 0, rw = 0, size = 0;
    sscanf(getenv("SHACK_JIT_POOL") ?: "", "%llx,%llx,%llx", &rx, &rw, &size);
    static const uint32_t ret42[2] = {0x52800540, 0xd65f03c0}, ret99[2] = {0x52800c60, 0xd65f03c0};   // mov w0,#n; ret
    int (*fn)(void) = (int (*)(void))(uintptr_t)rx;
    memcpy((void *)(uintptr_t)rw, ret42, sizeof ret42); sys_icache_invalidate((void *)(uintptr_t)rx, sizeof ret42);
    int first = fn();
    memcpy((void *)(uintptr_t)rw, ret99, sizeof ret99); sys_icache_invalidate((void *)(uintptr_t)rx, sizeof ret99);
    int second = fn();
    return [NSString stringWithFormat:@"JIT: %llu MB pool rx 0x%llx rw 0x%llx in %.1f s; ran %d then %d after rewrite (%@)\n",
            size >> 20, rx, rw, CFAbsoluteTimeGetCurrent() - start, first, second,
            first == 42 && second == 99 ? @"ok" : @"WRONG"];
}
