#import "MadeiraEngine.h"
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <os/proc.h>
#import <pthread.h>
#import "ShackJIT.h"
#import "EngineBundle.h"
#import "ShackPlay.h"

// Runs Madeira's Windows engine (Windows/engine in the App Group, laid out by MacShack's Set up Windows games: the
// release's Madeira.debug.dylib, GPL-3.0) in MacShack Play the way Madeira's own app does from its "x64 DX11 cube"
// button (its ContentView runWineFullSequence), minus the SwiftUI: JIT pool, wineserver, the Windows program, drawing
// into Play's own CAMetalLayer (madeira_display_set_layer). Calls go through dlsym: the engine stays a separate library.

// Madeira's pool rules (its StikJITHelper.allocatePool): RX at or above 0x119000000 (FEX's dispatcher emit is
// position-dependent below it) and outside the guest window [0x70, 0x80) GB. The debugger picks the RX address
// (only its own allocations become executable), so: pin low address space up to 0x119000000, and hold the whole
// guest band while it picks, so RX can only land in the hole above our images (~1.3 GB before the engine loads), or
// fail.
// That hole ends at the shared cache (0x180000000), and whatever Play maps before the engine starts can split it: on the
// iPad, 1 in ~5 launches had no 896 MB piece left (the script's "RX allocation failed: E53"). So main() holds the space
// (1 GB if it can, for slack against maps made while the debugger attaches) and preparePool gives it back just before
// the debugger picks RX, first fit, from the lowest free hole.
static vm_address_t gHeld;
static vm_size_t gHeldSize;

void MadeiraEngineHoldPoolSpace(void) {
    for (vm_size_t size = 1024u << 20; size >= (896u << 20) && !gHeld; size -= 128u << 20)
        for (vm_address_t a = 0x119000000; a + size <= 0x180000000; a += 16u << 20) {
            vm_address_t at = a;   // FIXED: fails, never moves or replaces, where something already is
            if (vm_allocate(mach_task_self(), &at, size, VM_FLAGS_FIXED) == KERN_SUCCESS) { gHeld = at; gHeldSize = size; break; }
        }
    // A fence page just below, kept for good (already taken is fine too): a free gap there, under the pins' 16 MB, would
    // join the space when it is given back, and RX would start below 0x119000000 (seen on the iPad: rx 0x1180e0000).
    vm_address_t fence = gHeld - vm_page_size;
    if (gHeld) vm_allocate(mach_task_self(), &fence, vm_page_size, VM_FLAGS_FIXED);
}

static NSString *preparePool(size_t mb) {
    for (int i = 0; i < 32; i++) {   // kept for the process's life, as Madeira does
        vm_address_t a = 0;
        if (vm_allocate(mach_task_self(), &a, 16u << 20, VM_FLAGS_ANYWHERE) != KERN_SUCCESS || a + (16u << 20) >= 0x119000000) break;
    }
    NSString *held = gHeld ? [NSString stringWithFormat:@"held %lu MB at 0x%lx from launch", (unsigned long)(gHeldSize >> 20), (unsigned long)gHeld]
                           : @"nothing held from launch: no 896 MB hole then";
    if (gHeld) vm_deallocate(mach_task_self(), gHeld, gHeldSize);
    gHeld = 0;
    // The guest band is held only while the debugger picks RX: the RW alias may then land at 0x7000000000, where
    // Madeira's engine expects it (its usable-VA floor is 0x7000000000 + pool size).
    if (!ShackJITPoolSetupAvoiding(mb << 20, 0x7000000000, 0x1000000000))
        return [NSString stringWithFormat:@"no JIT pool (debugger not attached, or no %zu MB hole above 0x119000000; %@)", mb, held];
    unsigned long long rx = 0, rw = 0, size = 0;
    sscanf(getenv("SHACK_JIT_POOL") ?: "", "%llx,%llx,%llx", &rx, &rw, &size);
    if (rx < 0x119000000 || (rx + size > 0x7000000000 && rx < 0x8000000000))
        return [NSString stringWithFormat:@"bad pool placement rx 0x%llx (%@)", rx, held];
    char v[32];
    snprintf(v, sizeof v, "%llx", rx); setenv("WINE_IOS_JIT_RX", v, 1);   // hex, no 0x (Madeira's format)
    snprintf(v, sizeof v, "%llx", rw); setenv("WINE_IOS_JIT_RW", v, 1);
    snprintf(v, sizeof v, "%llx", size); setenv("WINE_IOS_JIT_SIZE", v, 1);
    setenv("MADEIRA_DETACHED", "1", 1);
    return [NSString stringWithFormat:@"pool rx 0x%llx rw 0x%llx %llu MB (%@)", rx, rw, size >> 20, held];
}

// Input: the engine's own entry points (Madeira's app calls them from its game view and GamepadInput).
static void (*g_touch[3])(int, int);
static void (*g_padSet)(int, const ShackPadState *);
static _Atomic uint64_t g_touches, g_pads;

void MadeiraEngineTouch(NSInteger phase, double x, double y) {
    if (phase < 0 || phase > 2 || !g_touch[phase]) return;
    int w = getenv("MADEIRA_SCREEN_W") ? atoi(getenv("MADEIRA_SCREEN_W")) : 960;   // game coordinates, as Madeira's mapTouch
    int h = getenv("MADEIRA_SCREEN_H") ? atoi(getenv("MADEIRA_SCREEN_H")) : 540;
    g_touch[phase]((int)MIN(x * w, w - 1), (int)MIN(y * h, h - 1));
    g_touches++;
}

BOOL MadeiraEnginePad(NSInteger index, const ShackPadState *state) {
    static uint32_t packets[4];
    if (index < 0 || index > 3 || !g_padSet) return NO;
    if (!state) { g_padSet((int)index, NULL); g_pads++; return YES; }   // disconnected
    ShackPadState s = *state;
    s.packet = ++packets[index];   // Play sends only changes
    g_padSet((int)index, &s);
    g_pads++;
    return YES;
}

// Two fixes to Madeira's JIT-pool bookkeeping for Windows processes started by other Windows processes (NotProton's
// launch: launcher -> steam.exe -> game). Madeira runs every process in this one task, copies each PE image's code
// into its JIT pool (ios_jit_mappings: PE range -> pool copy, owner PEB set only for a child's own copy of the shared
// ntdll) and tells each process's FEX where the copies are. The engine's symbols are local, so they come from its symbol
// table; the table layout (0x50-byte entries: PE base, pool base, size, owner PEB at +0x40) is checked in the engine's
// own walk of it, and the calls are wrapped in the engine's dispatch tables (in the engine, under its locks: no code
// patching).
// 1. A new FEX gets only the shared entries (unix_ios_push_jit_aliases: "x86-64 children under FEX will need
//    per-process alias routing"), so a child's x64 code calling into ntdll jumps to an address its FEX cannot place
//    (steam.exe died on NtSetInformationProcess, [iOS-xquery] MISS, NoExecOp, right after starting the game). The wrapper
//    also pushes the binding process's own entries; FEX replaces the overlapping shared ntdll entry with them.
// 2. Unmapping an image leaves its entry, and a later image of the same size at the same address (another process's)
//    passes the engine's stale check (its headers look right) and runs the old one's code: after steam.exe freed
//    steamclient64.dll and imagehlp.dll, the game's nsi.dll ran imagehlp's copy and crashed. The wrapper of
//    NtUnmapViewOfSection(Ex) retires the entry the way the engine's own window purge does (size, then PE base, zeroed
//    under ios_pool_lock); the old copy stays in the pool, so a thread still in it does not fault.
// ponytail: images mapped later still go to whichever FEX bound last (the engine's single callback); route them per
// process too if a parent's x64 code calls a DLL it loads after starting a child.
typedef void (*AliasAdd)(unsigned long long pe, unsigned long long jit, unsigned long long size);
static int (*gPushAliases)(void *args);   // NTSTATUS
static int (*gUnmap)(void *process, void *addr);
static int (*gUnmapEx)(void *process, void *addr, unsigned flags);
static char *gMappings;
static const int *gMappingCount;
static void *(*gCurrentPeb)(void);   // the engine's ios_jit_current_peb: what it records as an entry's owner
static pthread_mutex_t *gPoolLock;
#define MAP_ENTRY(i) (gMappings + (i) * 0x50)
#define MAP_PE(e) (*(uint64_t *)(e))
#define MAP_POOL(e) (*(uint64_t *)((e) + 8))
#define MAP_SIZE(e) (*(uint64_t *)((e) + 0x10))
#define MAP_OWNER(e) (*(void **)((e) + 0x40))

static int pushAliases(void *args) {
    int status = gPushAliases(args);
    AliasAdd add = args ? *(AliasAdd *)args : NULL;
    void *peb = gCurrentPeb();
    if (status || !add || !peb) return status;
    for (int i = 0; i < *gMappingCount; i++)
        if (MAP_OWNER(MAP_ENTRY(i)) == peb && MAP_PE(MAP_ENTRY(i))) add(MAP_PE(MAP_ENTRY(i)), MAP_POOL(MAP_ENTRY(i)), MAP_SIZE(MAP_ENTRY(i)));
    return status;
}

static void retireImage(uint64_t addr) {
    pthread_mutex_lock(gPoolLock);
    for (int i = 0; i < *gMappingCount; i++) {
        char *e = MAP_ENTRY(i);
        if (MAP_OWNER(e) || !MAP_PE(e) || addr < MAP_PE(e) || addr >= MAP_PE(e) + MAP_SIZE(e)) continue;
        MAP_SIZE(e) = 0;
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        MAP_PE(e) = 0;
    }
    pthread_mutex_unlock(gPoolLock);
}

static int unmapView(void *process, void *addr) {
    int status = gUnmap(process, addr);
    if (!status) retireImage((uint64_t)addr);
    return status;
}

static int unmapViewEx(void *process, void *addr, unsigned flags) {
    int status = gUnmapEx(process, addr, flags);
    if (!status) retireImage((uint64_t)addr);
    return status;
}

// Replaces table[slot] (in the engine's read-only data) with fn and returns what was there.
static void *swapEntry(void **table, int slot, void *fn) {
    vm_address_t page = (vm_address_t)&table[slot] & ~(vm_address_t)(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE)) return NULL;
    void *old = table[slot];
    table[slot] = fn;
    vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ);
    return old;
}

static NSString *fixPoolBookkeeping(void) {
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count() && !mh; i++)
        if (strstr(_dyld_get_image_name(i), "/Madeira.debug.dylib")) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
        }
    if (!mh) return @"no engine image";
    const struct symtab_command *st = NULL;
    const struct segment_command_64 *linkedit = NULL, *text = NULL;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_TEXT)) text = (const void *)lc;
    }
    if (!st || !linkedit || !text) return @"no symbol table";
    const char *base = (const char *)(slide + linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *syms = (const void *)(base + st->symoff);
    const char *strs = base + st->stroff;
    enum { CALLS, PUSH, MAPPINGS, COUNT, PEB, LOCK, SYSCALLS, UNMAP, UNMAPEX, NAMES };
    static const char *names[NAMES] = { "_unix_call_funcs", "_unixcall_ios_push_jit_aliases", "_ios_jit_mappings",
        "_ios_jit_mapping_count", "_ios_jit_current_peb", "_ios_pool_lock", "_syscalls", "_NtUnmapViewOfSection",
        "_NtUnmapViewOfSectionEx" };
    uintptr_t found[NAMES] = { 0 }, tables[2] = { 0 };   // _syscalls: ntdll's and win32u's
    for (uint32_t i = 0; i < st->nsyms; i++) {
        if (syms[i].n_type & N_STAB || !syms[i].n_value) continue;
        for (int n = 0; n < NAMES; n++)
            if (!found[n] && !strcmp(strs + syms[i].n_un.n_strx, names[n])) found[n] = syms[i].n_value + slide;
        if (!strcmp(strs + syms[i].n_un.n_strx, "_syscalls")) tables[!!tables[0]] = syms[i].n_value + slide;
    }
    for (int n = 0; n < NAMES; n++) if (!found[n]) return [NSString stringWithFormat:@"no %s", names[n]];
    for (int t = 0; t < 2 && tables[t]; t++)   // ntdll's is the one holding NtUnmapViewOfSection
        for (int i = 0; i < 1024; i++) if (((void **)tables[t])[i] == (void *)found[UNMAP]) found[SYSCALLS] = tables[t];
    const uint32_t *code = (const uint32_t *)found[PUSH];
    BOOL stride = NO, owner = NO;   // add x22, x22, #0x50 and ldr x9, [x22, #0x40]: the engine's own walk of the table
    for (int i = 0; i < 0x80; i++) { stride |= code[i] == 0x910142d6; owner |= code[i] == 0xf94022c9; }
    if (!stride || !owner) return @"mapping table layout differs (engine changed)";
    void **calls = (void **)found[CALLS], **syscalls = (void **)found[SYSCALLS];
    int push = 0, unmap = 0, unmapEx = 0;
    for (; push < 512; push++) {   // the push itself, or a function that calls or jumps to it (B/BL) early on
        const uint32_t *fn = calls[push];
        BOOL hit = fn == (const void *)found[PUSH];
        for (int i = 0; i < 64 && !hit && (uintptr_t)fn >= (uintptr_t)mh && (uintptr_t)(fn + 64) <= (uintptr_t)mh + text->vmsize; i++)
            hit = (fn[i] & 0x7c000000) == 0x14000000 &&
                  (uintptr_t)(fn + i) + ((int64_t)((int32_t)(fn[i] << 6) >> 6) << 2) == found[PUSH];
        if (hit) break;
    }
    while (unmap < 1024 && syscalls[unmap] != (void *)found[UNMAP]) unmap++;
    while (unmapEx < 1024 && syscalls[unmapEx] != (void *)found[UNMAPEX]) unmapEx++;
    if (push == 512 || unmap == 1024 || unmapEx == 1024) return @"a call is not in the engine's tables";
    gMappings = (char *)found[MAPPINGS];
    gMappingCount = (const int *)found[COUNT];
    gCurrentPeb = (void *)found[PEB];
    gPoolLock = (pthread_mutex_t *)found[LOCK];
    gPushAliases = calls[push];
    gUnmap = syscalls[unmap];
    gUnmapEx = syscalls[unmapEx];
    if (!swapEntry(calls, push, pushAliases) || !swapEntry(syscalls, unmap, unmapView) || !swapEntry(syscalls, unmapEx, unmapViewEx))
        return @"a table is not writable";
    return [NSString stringWithFormat:@"wrapped unix call %d, syscalls %d and %d", push, unmap, unmapEx];
}

static NSString *logTail(NSString *path, NSUInteger bytes) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return @"(no log)";
    NSUInteger from = d.length > bytes ? d.length - bytes : 0;
    return [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(from, d.length - from)] encoding:NSUTF8StringEncoding]
           ?: @"(log not UTF-8)";
}

// A Steam game folder seen where Steam games live in a prefix (and where Madeira's own library puts them):
// C:\Program Files (x86)\Steam\steamapps\common\<game> is a link to the folder (in the App Group's Steam library).
static NSString *linkGame(NSString *prefix, NSString *game, NSString *folder) {
    NSString *common = [prefix stringByAppendingPathComponent:@"drive_c/Program Files (x86)/Steam/steamapps/common"];
    NSString *link = [common stringByAppendingPathComponent:game];
    [NSFileManager.defaultManager createDirectoryAtPath:common withIntermediateDirectories:YES attributes:nil error:nil];
    unlink(link.fileSystemRepresentation);   // an earlier run's link (never a real folder: rmdir would be needed)
    if (symlink(folder.fileSystemRepresentation, link.fileSystemRepresentation)) return [NSString stringWithFormat:@"link failed: %s", strerror(errno)];
    return [NSString stringWithFormat:@"linked %@ -> %@", game, folder];
}

NSString *MadeiraEngineDirectory(void) {
    NSString *macshack = [NSBundle.mainBundle.bundleIdentifier stringByDeletingPathExtension];   // Play's id is MacShack's + ".play"
    NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:ShackPlayGroup(macshack)];
    return group ? [group.path stringByAppendingPathComponent:@"Windows/engine"] : nil;
}

NSString *MadeiraEngineRun(NSDictionary *request, CAMetalLayer *layer) {
    NSMutableString *o = [NSMutableString string];
    NSString *dir = MadeiraEngineDirectory(), *dylib = [dir stringByAppendingPathComponent:@"Madeira.debug.dylib"];
    if (!dylib || ![NSFileManager.defaultManager fileExistsAtPath:dylib])   // before the pool: no address space pinned, no debugger waited for
        return [o stringByAppendingString:@"engine: Windows games are not set up (MacShack > Settings > Windows games)\n"];
    NSString *exe = request[@"run"], *game = request[@"game"];
    NSArray<NSString *> *screen = [request[@"screen"] ?: (game ? @"1408x648" : @"960x540") componentsSeparatedByString:@"x"];
    int screenW = screen.count == 2 ? screen[0].intValue : 960, screenH = screen.count == 2 ? screen[1].intValue : 540;
    size_t jitMB = [request[@"jitMB"] unsignedLongValue] ?: (game ? 896 : 384);   // Madeira's sizes: games, test programs
    NSString *pool = preparePool(jitMB);
    [o appendFormat:@"engine: %@\n", pool];
    if (!getenv("WINE_IOS_JIT_RX")) return o;

    void *engine = dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);   // GLOBAL: DXMT dlsyms macdrv_functions
    if (!engine) return [o stringByAppendingFormat:@"engine: not loaded (%s)\n", dlerror()];
    int (*wineserverStart)(const char *) = dlsym(engine, "wineserver_start");
    int (*wineProcessStart)(const char *) = dlsym(engine, "wine_process_start");
    void (*setLayer)(CAMetalLayer *) = dlsym(engine, "madeira_display_set_layer");
    uint64_t (*presents)(void) = dlsym(engine, "madeira_get_present_count");
    void (*trapHandler)(void) = dlsym(engine, "jit_install_trap_handler");
    volatile int *quiet = dlsym(engine, "ws_log_quiet");
    int (*running)(void) = dlsym(engine, "wine_process_is_running");
    void (*vsync)(int32_t) = dlsym(engine, "madeira_set_vsync_locked");
    g_touch[0] = dlsym(engine, "winios_post_touch_down");
    g_touch[1] = dlsym(engine, "winios_post_touch_move");
    g_touch[2] = dlsym(engine, "winios_post_touch_up");
    g_padSet = dlsym(engine, "winios_gamepad_set_state");
    if (!wineserverStart || !wineProcessStart || !setLayer || !presents || !trapHandler)
        return [o stringByAppendingString:@"engine: an entry point is missing\n"];
    ShackEngineBundleRedirect((const void *)wineserverStart, dir);   // the engine's own files: Windows/engine, not Play's bundle
    [o appendFormat:@"engine: loaded %@\n", dylib.lastPathComponent];
    [o appendFormat:@"engine: JIT-pool bookkeeping for child processes: %@\n", fixPoolBookkeeping()];
    // Unix halves of Play's own builtins (Windows/engine/aarch64-unix: lsteamclient, from windows-kit). This engine binds a
    // builtin it does not know to a stub table (its iOS loader keeps no unix_path for them), so Play loads each here, after
    // the engine whose exports they bind to, and hands its call table to the PE half: MONO_MACSHACK_UNIXLIB_<NAME> = the
    // table's address (Madeira passes only Steam*, FNA3D_* and MONO_* variables to Windows; windows-kit's lsteamclient
    // patch reads it).
    NSString *unixDir = [dir stringByAppendingPathComponent:@"aarch64-unix"];
    for (NSString *so in [NSFileManager.defaultManager contentsOfDirectoryAtPath:unixDir error:nil]) {
        void *h = dlopen([unixDir stringByAppendingPathComponent:so].fileSystemRepresentation, RTLD_NOW);
        void *funcs = h ? dlsym(h, "__wine_unix_call_funcs") : NULL;
        NSString *name = [@"MONO_MACSHACK_UNIXLIB_" stringByAppendingString:so.stringByDeletingPathExtension.uppercaseString];
        if (funcs) setenv(name.UTF8String, [NSString stringWithFormat:@"%llx", (unsigned long long)(uintptr_t)funcs].UTF8String, 1);
        [o appendFormat:@"engine: unix library %@: %s\n", so, funcs ? [NSString stringWithFormat:@"call table %p -> %@", funcs, name].UTF8String : h ? "no __wine_unix_call_funcs" : dlerror()];
    }

    // What Madeira's library sets for a launch (its LibraryEntry.applyEnvironment/configureLaunch).
    NSString *gameDir = game ? [@"C:\\Program Files (x86)\\Steam\\steamapps\\common\\" stringByAppendingString:game] : nil;
    BOOL absolute = exe.length > 1 && [exe characterAtIndex:1] == ':';   // C:\... (steam.exe starting the game, for the Steam API in Windows games)
    setenv("MADEIRA_EXE", (gameDir && !absolute ? [NSString stringWithFormat:@"%@\\%@", gameDir, exe] : exe).UTF8String, 1);
    if (gameDir) setenv("MADEIRA_WORKDIR", gameDir.UTF8String, 1);   // the game's folder, whoever starts it
    setenv("MADEIRA_ARGS", [request[@"args"] ?: @"" UTF8String], 1);
    if (request[@"steamAppID"]) {   // Madeira's "Start with: The game": the program's own Steam identity (SteamAppId,
        setenv("MADEIRA_STEAM_APPID", [request[@"steamAppID"] description].UTF8String, 1);   // SteamGameId, SteamAppPath)
        setenv("MADEIRA_STEAM_APPPATH", (gameDir ?: @"C:\\").UTF8String, 1);
    }
    setenv("MADEIRA_SCREEN_W", @(screenW).stringValue.UTF8String, 1);
    setenv("MADEIRA_SCREEN_H", @(screenH).stringValue.UTF8String, 1);
    if (vsync) vsync([request[@"fpsMode"] intValue] ?: 1);
    if (quiet) *quiet = 1;
    trapHandler();   // a later brk (no debugger now) is skipped instead of killing us, as in Madeira's app

    dispatch_sync(dispatch_get_main_queue(), ^{   // Madeira's MetalHostView layer: the program's image, aspect fit
        layer.device = MTLCreateSystemDefaultDevice();
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;   // DXMT may blit into the drawable
        layer.drawableSize = CGSizeMake(screenW, screenH);
        layer.contentsGravity = kCAGravityResizeAspect;
        if ([request[@"hud"] boolValue]) layer.developerHUDProperties = @{@"mode": @"default", @"logging": @"default"};
        setLayer(layer);
    });

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *prefix = request[@"prefix"] ?: [docs stringByAppendingPathComponent:@"wine"];   // a Steam game's own, or Play's
    [NSFileManager.defaultManager createDirectoryAtPath:prefix.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    static dispatch_source_t status;   // Documents/engine-status.txt every 2 s: devicectl copies only the first 10 MB
    status = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(status, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);   // of a long engine log
    dispatch_source_set_event_handler(status, ^{
        task_vm_info_data_t vi = {0}; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n);
        NSString *line = [NSString stringWithFormat:@"%@ presents %llu footprint %llu MB limit %llu MB\n", NSDate.date, presents(),
                          vi.phys_footprint >> 20, (vi.phys_footprint + os_proc_available_memory()) >> 20];
        [line writeToFile:[docs stringByAppendingPathComponent:@"engine-status.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    dispatch_resume(status);
    [o appendFormat:@"engine: wineserver_start %d (%@)\n", wineserverStart(prefix.fileSystemRepresentation), prefix];   // seeds the prefix
    if (game) [o appendFormat:@"engine: %@\n", linkGame(prefix, game, request[@"gameDir"])];
    sleep(2);   // as Madeira's app does before the Windows process
    // NotProton's steam.exe exits when only "system" processes are left: Wine signals that event once no user program has
    // run for the server's persistence time (Wine's default 3 s). Madeira's in-app server never times out (main_ios.c),
    // so for NotProton's launch Play restores Wine's default once the server is up. After the game has quit, the server
    // then shuts down as NotProton's Wine does: the event, a registry flush, and its thread ends (Madeira: pthread_exit).
    int64_t *persist = request[@"wineDefaultShutdown"] ? dlsym(engine, "master_socket_timeout") : NULL;
    if (persist) *persist = 3 * -10000000LL;   // timeout_t: relative, in 100 ns ticks
    [o appendFormat:@"engine: wine_process_start %d\n", wineProcessStart(prefix.fileSystemRepresentation)];

    // Until the program exits (a game), or `seconds` of frames (default 20, Madeira's test programs); 2 min for a first frame.
    double seconds = [request[@"seconds"] doubleValue] ?: (game ? 86400 : 20);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(), first = 0;
    while (CFAbsoluteTimeGetCurrent() - start < 120 || first) {
        if (!first && presents() >= 1) first = CFAbsoluteTimeGetCurrent();
        if (first && CFAbsoluteTimeGetCurrent() - first > seconds) break;
        if (running && !running() && CFAbsoluteTimeGetCurrent() - start > 5) { [o appendString:@"engine: the Windows program exited\n"]; break; }
        usleep(250000);
    }
    uint64_t n = presents();
    [o appendFormat:@"engine: input: %llu touch events, %llu pad updates\n", (unsigned long long)g_touches, (unsigned long long)g_pads];
    [o appendFormat:@"engine: %@; %llu presents%@\n",
        first ? [NSString stringWithFormat:@"first frame %.1f s after start", first - start] : @"NO frame in 120 s",
        n, first ? [NSString stringWithFormat:@", %.1f fps", n / (CFAbsoluteTimeGetCurrent() - first)] : @""];
    [o appendFormat:@"--- madeira-log.txt (tail)\n%@\n", logTail([docs stringByAppendingPathComponent:@"madeira-log.txt"], 6000)];
    return o;
}
