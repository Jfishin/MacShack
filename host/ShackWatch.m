#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>
#import <signal.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <os/proc.h>
#import "ShackWatch.h"
#import "ShackSwap.h"
#import "ShackMetal.h"

// Shipping games log nothing, so every 10 s the log gets available memory (jetsam diagnosis) and the top frames
// of the engine's main threads (hang diagnosis). Frames are image+offset for atos -l against the Mac binary.
// Logged: the game thread (unnamed; its stack runs through GuardedMain), render and RHI threads. Threads inside a
// Metal pipeline compile are only counted (first launch compiles thousands of them).
static pthread_t gMainThread;
__attribute__((constructor)) static void rememberMainThread(void) { gMainThread = pthread_self(); }   // image load runs on the main thread
static void sample(void) {
    int compiling = 0;
    thread_act_array_t threads; mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return;
    thread_t me = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        pthread_t pt = pthread_from_mach_thread_np(threads[i]); char name[64] = "";
        if (pt) pthread_getname_np(pt, name, sizeof name);
        if (threads[i] == me || !pt) continue;
        uintptr_t lo = (uintptr_t)pthread_get_stackaddr_np(pt) - pthread_get_stacksize_np(pt), hi = (uintptr_t)pthread_get_stackaddr_np(pt);
        uintptr_t pcs[40]; int k = 0;
        // No allocation or locks while the thread is suspended: it may hold them.
        if (thread_suspend(threads[i]) == KERN_SUCCESS) {
            arm_thread_state64_t st; mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &c) == KERN_SUCCESS) {
                pcs[k++] = (uintptr_t)arm_thread_state64_get_pc(st);
                pcs[k++] = (uintptr_t)arm_thread_state64_get_lr(st);
                for (uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st); k < 40 && fp >= lo && fp + 16 <= hi && !(fp & 7); fp = ((uintptr_t *)fp)[0])
                    pcs[k++] = ((uintptr_t *)fp)[1];
            }
            thread_resume(threads[i]);
        }
        NSMutableString *s = [NSMutableString stringWithFormat:@"[MacShack] thread '%s':", name]; BOOL guest = NO;
        for (int j = 0; j < k; j++) {
            Dl_info d = {0}; uintptr_t pc = pcs[j] & 0x0000000FFFFFFFFFull;   // strip PAC bits
            if (dladdr((void *)pc, &d) && d.dli_fname) {
                guest |= strstr(d.dli_fname, "/Guests/") != NULL;
                const char *slash = strrchr(d.dli_fname, '/');
                [s appendFormat:@" %s+0x%lx(%s)", slash ? slash + 1 : d.dli_fname, pc - (uintptr_t)d.dli_fbase, d.dli_sname ?: "?"];
            } else [s appendFormat:@" 0x%lx", pc];
        }
        const char *line = s.UTF8String;
        if (strstr(line, "PipelineState")) compiling++;
        else if (guest || pt == gMainThread || strstr(line, "libOcerz")) NSLog(@"%@", s);   // every thread running game code (translated games: through libOcerz), and UIKit's main thread
    }
    if (compiling) NSLog(@"[MacShack] %d threads compiling Metal pipelines", compiling);
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    mach_port_deallocate(mach_task_self(), me);
}

// CPU time per thread since the last call: the busiest, as % of one core, and the whole process. A thread near 100%
// while the GPU has headroom is what holds the frame rate; the total is what heats the phone.
static NSString *busiestThreads(double secs) {
    enum { NT = 512, TOP = 6 };
    static struct { uint64_t id; double t; } prev[NT], cur[NT]; static unsigned nprev;
    struct { double d; char name[40]; } top[TOP] = {0};
    double total = 0; unsigned busy = 0;
    thread_act_array_t threads; mach_msg_type_number_t n, ncur = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return @"";
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t idi; thread_basic_info_data_t bi;
        mach_msg_type_number_t c1 = THREAD_IDENTIFIER_INFO_COUNT, c2 = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&idi, &c1) == KERN_SUCCESS &&
            thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c2) == KERN_SUCCESS && ncur < NT) {
            double t = bi.user_time.seconds + bi.system_time.seconds + (bi.user_time.microseconds + bi.system_time.microseconds) / 1e6, d = t;
            for (unsigned j = 0; j < nprev; j++) if (prev[j].id == idi.thread_id) { d = t - prev[j].t; break; }
            cur[ncur].id = idi.thread_id; cur[ncur++].t = t;
            total += d; busy += d > 0.01 * secs;
            for (int k = 0; k < TOP; k++) if (d > top[k].d) {
                memmove(&top[k + 1], &top[k], (TOP - 1 - k) * sizeof top[0]);
                top[k].d = d; top[k].name[0] = 0;
                pthread_t pt = pthread_from_mach_thread_np(threads[i]);
                if (pt) pthread_getname_np(pt, top[k].name, sizeof top[k].name);
                if (!top[k].name[0]) snprintf(top[k].name, sizeof top[k].name, "#%llu", idi.thread_id);
                break;
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    memcpy(prev, cur, ncur * sizeof cur[0]); nprev = ncur;
    NSMutableString *s = [NSMutableString stringWithFormat:@"%.0f%% in all (%u threads over 1%%):", 100 * total / secs, busy];
    for (int k = 0; k < TOP && top[k].d > 0; k++) [s appendFormat:@"%@ '%s' %.0f%%", k ? @"," : @"", top[k].name, 100 * top[k].d / secs];
    return s;
}

// What decides the phone's power and heat besides the load line: the OS's power state, the display links the guests
// drive (Chromium draws one frame per tick) and whether the Steam client sleeps behind a game.
static _Atomic float gBattery = -1; static _Atomic int gBatteryState;
static NSString *powerState(int secs) {
    static const char *thermal[] = {"nominal", "fair", "serious", "critical"};   // serious/critical: iOS throttles
    dispatch_async(dispatch_get_main_queue(), ^{   // UIDevice is main-thread API; read for the next line
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        gBattery = UIDevice.currentDevice.batteryLevel; gBatteryState = (int)UIDevice.currentDevice.batteryState;
    });
    static uint64_t (*cvStats)(unsigned *, unsigned *); static dispatch_once_t once;
    dispatch_once(&once, ^{ cvStats = (uint64_t (*)(unsigned *, unsigned *))dlsym(RTLD_DEFAULT, "ShackCVTakeStats"); });
    unsigned running = 0, sleeping = 0; uint64_t ticks = cvStats ? cvStats(&running, &sleeping) : 0;
    int cap = ShackMetalFrameCap();
    return [NSString stringWithFormat:@"thermal %s, low power %s, battery %.0f%%%s, cap %@, display links %u (%u asleep) %.0f ticks/s",
            thermal[NSProcessInfo.processInfo.thermalState & 3], NSProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
            gBattery < 0 ? 0 : 100 * gBattery, gBatteryState == UIDeviceBatteryStateUnplugged ? " unplugged" : gBatteryState > 1 ? " charging" : "",
            cap ? [NSString stringWithFormat:@"%d", cap] : @"off", running, sleeping, (double)ticks / secs];
}

void ShackWatchStart(BOOL fullWatch) {
    [NSThread detachNewThreadWithBlock:^{
        pthread_setname_np("shack-watch");
        NSString *logs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"Logs"];
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            NSLog(@"[MacShack] thermal state now %ld (0 nominal .. 3 critical)", (long)NSProcessInfo.processInfo.thermalState);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            NSLog(@"[MacShack] low power mode %s", NSProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off");
        }];
        for (int tick = 1;; tick++) {
            [NSThread sleepForTimeInterval:10];
            // Cheap and useful, so it stays on for every guest, with no thread suspension. Every 10 s while we tune
            // power and heat (ponytail: back to once a minute, plus every 10 s when memory runs short, once that is done).
            {
                char swap[160]; ShackSwapStats(swap, sizeof swap);
                static unsigned (*glFrames)(void); static dispatch_once_t once;
                dispatch_once(&once, ^{ glFrames = (unsigned (*)(void))dlsym(RTLD_DEFAULT, "ShackGLTakeFrameCount"); });   // desktop-GL games
                static NSTimeInterval last; NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                int secs = (int)((last ? now - last : 10) + 0.5); last = now;   // since the previous line
                unsigned frames = glFrames ? glFrames() : 0;
                NSString *gl = frames ? [NSString stringWithFormat:@", GL %.1f fps", (double)frames / secs] : @"";
                unsigned drawables = ShackMetalTakeDrawableCount();
                NSLog(@"[MacShack] mem available %zu MB (Metal holds %llu MB, %s), %u drawables in %d s%@, %@", os_proc_available_memory() >> 20,
                      ShackMetalAllocatedBytes() >> 20, swap, drawables, secs, gl, powerState(secs));
                double gpu = ShackMetalTakeGPUBusy();
                NSLog(@"[MacShack] load: gpu %.0f%% (%.1f ms per drawable), cpu %@", 100 * gpu / secs, drawables ? 1000 * gpu / drawables : 0,
                      busiestThreads(secs));
            }
            if (tick % 6 == 0) { NSString *p = ShackMetalTakePacing(); if (p) NSLog(@"[MacShack] %@", p); }
            // GPU trace on request: `touch` Documents/Logs/gputrace.request from the Mac (game launched with --shack-gputrace).
            NSString *req = [logs stringByAppendingPathComponent:@"gputrace.request"];
            if ([NSFileManager.defaultManager removeItemAtPath:req error:nil]) ShackMetalCaptureTrace([logs stringByAppendingPathComponent:@"frame.gputrace"]);
            if (!fullWatch) continue;   // stack sampling and frame capture are opt-in: --shack-watch / SHACK_WATCH=1
            if (tick % 6 == 0) ShackMetalCaptureFrame([logs stringByAppendingFormat:@"/frame-%03ds.png", tick * 10]);   // what the screen shows, once a minute
            sample();
            if (getenv("OCERZ_JIT_POOL")) kill(getpid(), SIGINFO);   // translated game: AArchX dumps every guest thread (rip, rsp) to the log
        }
    }];
}
