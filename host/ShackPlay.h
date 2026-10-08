#import <Foundation/Foundation.h>
#import <mach/mach.h>
#if TARGET_OS_IPHONE
#import <os/proc.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// MacShack Play (README, "Windows games"). MacShack and the Play app share the
// App Group group.<MacShack's bundle id>; MacShack registers a Mach service named inside it (the sandbox allows
// `<group>.*` names), Play looks it up and says hello, and the reply carries a session port Play then uses: a port right
// crossing between two apps, as Steam's ipcserver port will.

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;   // the hello reply's session port; null otherwise
    int32_t kind;                      // ShackPlayHello / Ping / JIT
    int32_t pid;                       // the sender's
    uint64_t value;                    // echoed back unless the handler sets it
} ShackPlayMessage;

// Ping replies carry ShackPlayQuit in `value` when Steam asked the game to stop; Exited carries the exit status.
// SteamIPC's reply carries a send right to MacShack's Steam ipcserver (com.valvesoftware.steam.ipctool), or null.
enum { ShackPlayHello = 1, ShackPlayPing = 2, ShackPlayJIT = 3, ShackPlayExited = 4, ShackPlaySteamIPC = 5 };
enum { ShackPlayQuit = 1 };
// The process Steam sees for whatever runs in MacShack Play (MacShack's stand-in pid; Play's Steam images report it too).
enum { ShackPlaySteamPid = 1000003 };

// MacShack: registers `name` and answers each request on `queue`; `handle` may change the reply (kind, pid and value
// preset; a port right in `port`, name and disposition). A hello's reply carries the session port (ponytail: one for every client, one Play at a time); `gone`
// (optional, on `queue`) runs when every client's session right is gone: MacShack Play's process ended, however it
// ended. Returns the bootstrap result (0 = registered).
kern_return_t ShackPlayServe(const char *name, dispatch_queue_t queue,
                             void (^handle)(const ShackPlayMessage *request, ShackPlayMessage *reply),
                             void (^_Nullable gone)(void));
// Play: looks `name` up and says hello; on success *session is MacShack's session port (a send right).
kern_return_t ShackPlayConnect(const char *name, mach_port_t *session);
// One request and its reply, each leg within timeoutMs. MACH_SEND_INVALID_DEST: the server is gone;
// MACH_RCV_TIMED_OUT: it did not answer (suspended or busy).
kern_return_t ShackPlayCall(mach_port_t port, int32_t kind, uint64_t value, int timeoutMs, ShackPlayMessage *reply);
const char *ShackPlayError(kern_return_t kr);   // bootstrap and Mach codes as text

static inline NSString *ShackPlayGroup(NSString *macshackBundleID) { return [@"group." stringByAppendingString:macshackBundleID]; }
static inline NSString *ShackPlayService(NSString *macshackBundleID) { return [ShackPlayGroup(macshackBundleID) stringByAppendingString:@".play"]; }

#if TARGET_OS_IPHONE
static inline uint64_t ShackPlayFootprint(void) {
    task_vm_info_data_t vm;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &n) == KERN_SUCCESS ? vm.phys_footprint : 0;
}
static inline uint64_t ShackPlayLimitMB(void) { return (ShackPlayFootprint() + os_proc_available_memory()) >> 20; }
static inline NSString *ShackPlayUsage(void) {
    return [NSString stringWithFormat:@"footprint %llu MB, available %llu MB, limit %llu MB", ShackPlayFootprint() >> 20,
            (uint64_t)os_proc_available_memory() >> 20, ShackPlayLimitMB()];
}
#endif

// MacShack only (host/ShackPlay.m): opens MacShack Play in `mode` ("probe": the bridge checks (`--play-probe`), query
// minutes; "run": a Windows program, query exe and, for a Steam game, install, compat, appid, args; or jitMB, seconds,
// screen, hud; "steam": Valve's steamclient logs on to MacShack's Steam from Play, query appid, seconds) with
// MacShack's side of the bridge and silent audio that keeps MacShack (and Steam) running in the background while the
// program is out. `ended` (optional, on the bridge's queue) gets its exit status: -1 when Play's process ended
// without reporting one. One program at a time: another while one is out gets EAGAIN at once. Documents/Logs/
// play-<mode>.txt has MacShack's lines, then Play's report when MacShack is back in front.
void ShackPlayStart(NSString *mode, NSDictionary<NSString *, NSString *> *query, void (^_Nullable ended)(int status));
// Steam's Stop: the program's next ping tells MacShack Play to quit.
void ShackPlayRequestQuit(void);
// MacShack's bundle id, read at load (once a guest runs, mainBundle answers for the guest). Play's is this + ".play".
NSString *ShackPlayHostBundleID(void);
// Windows games are set up: Windows/setup.json in the App Group (host/WindowsSetup.swift writes it last). Any thread.
BOOL ShackWindowsGamesSetUp(void);
// Steam Play is on: Windows games set up and MacShack Play installed (it answers its URL scheme). Main thread
// (UIApplication canOpenURL); ShackLoader asks it before each Steam start.
BOOL ShackWindowsGamesOn(void);

NS_ASSUME_NONNULL_END
