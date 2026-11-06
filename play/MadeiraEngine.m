#import "MadeiraEngine.h"
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <os/proc.h>
#import "ShackJIT.h"
#import "EngineBundle.h"
#import "ShackPlay.h"
#import "vendor/fishhook.h"

// Runs Madeira's Windows engine (Windows/engine in the App Group, laid out by MacShack's Set up Windows games: the
// release's app executable made a library, MadeiraEngine.dylib, GPL-3.0) in MacShack Play the way Madeira's own app does
// from its "x64 DX11 cube" button (its ContentView runWineFullSequence), minus the SwiftUI: JIT pool, wineserver, the
// Windows program, drawing into Play's own CAMetalLayer (madeira_display_set_layer). Calls go through dlsym: the engine
// stays a separate library.

// Madeira's pool rules (its StikJITHelper.allocatePool): RX at or above 0x119000000 (FEX's dispatcher emit is
// position-dependent below it) and outside the guest window [0x70, 0x80) GB. The debugger picks the RX address
// (only its own allocations become executable), so: pin low address space up to 0x119000000, and hold the whole
// guest band while it picks, so RX can only land in the hole above our images (~1.3 GB before the engine loads), or
// fail.
// That hole ends at the shared cache (0x180000000), and whatever Play maps before the engine starts can split it: on the
// iPad, 1 in ~5 launches had no 896 MB piece left (the script's "RX allocation failed: E53"). So main() holds the space
// (1 GB if it can, for slack against maps made while the debugger attaches) and preparePool gives it back just before
// the debugger picks RX, first fit, from the lowest free hole.
// malloc's first regions can land inside the hole before main (iPhone, Hi-Fi Rush: 8 MB at 0x143d00000, two 685 MB
// pieces left), so the hold takes down to 640 MB, and a pool asked for more than was held gets the held size less the
// same 128 MB of slack (512 MB at least, what fixed-base games run with).
// A Windows .exe without relocations (GameMaker's x64 runner: Advent NEON) loads only at its link base, 0x140000000,
// in that hole: Madeira runs every Windows process in Play's address space. The hole ends below the main thread's stack
// (~0x16b000000), so no 896 MB piece lies beside that address: such a game gets a 512 MB pool, and Play holds its image
// range from before the pool is picked until the engine maps the game there (imageMap): the engine's libraries, which
// dyld puts in the lowest gap above the pool, and macshack-launch.exe and steam.exe, which link there too, go elsewhere.
// ponytail: 512 MB fits below 0x140000000 with slack; a fixed-base game that outgrows it needs the largest free piece.
static BOOL FixedImageRange(NSString *path, vm_address_t *base, vm_size_t *size) {
    NSData *d = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL] : nil;
    const uint8_t *b = d.bytes;
    if (d.length < 0x40 || b[0] != 'M' || b[1] != 'Z') return NO;
    uint32_t pe = OSReadLittleInt32(b, 0x3c);
    if ((NSUInteger)pe + 84 > d.length || memcmp(b + pe, "PE\0\0", 4) || OSReadLittleInt16(b, pe + 24) != 0x20b) return NO;   // PE32+
    if (!(OSReadLittleInt16(b, pe + 22) & 1)) return NO;   // IMAGE_FILE_RELOCS_STRIPPED
    *base = OSReadLittleInt64(b, pe + 48); *size = OSReadLittleInt32(b, pe + 80);
    return *base < 0x180000000 && *base + *size > 0x119000000;
}

// The engine maps an image at its link base with anon_mmap_tryfixed: mach_vm_map, VM_FLAGS_FIXED there, the image's
// size. Called so for the held range, the hold goes first; anything else asking for it (steam.exe at its own size,
// a VirtualAlloc there) finds it taken and goes elsewhere.
static mach_vm_address_t gImageHeld;
static mach_vm_size_t gImageSize;
static kern_return_t (*gMachVmMap)(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t, int, mem_entry_name_port_t,
                                   memory_object_offset_t, boolean_t, vm_prot_t, vm_prot_t, vm_inherit_t);
static kern_return_t imageMap(vm_map_t task, mach_vm_address_t *address, mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                              mem_entry_name_port_t object, memory_object_offset_t offset, boolean_t copy, vm_prot_t cur,
                              vm_prot_t max, vm_inherit_t inheritance) {
    mach_vm_address_t held = gImageHeld;
    if (held && *address == held && !(flags & VM_FLAGS_ANYWHERE) && size >= gImageSize && size < gImageSize + (1u << 20) &&
        __sync_bool_compare_and_swap(&gImageHeld, held, 0))
        vm_deallocate(mach_task_self(), held, gImageSize);
    return gMachVmMap(task, address, size, mask, flags, object, offset, copy, cur, max, inheritance);
}

static NSString *releaseImageOnItsMap(const void *engineSymbol) {
    Dl_info info;
    for (uint32_t i = 0; gImageHeld && dladdr(engineSymbol, &info) && i < _dyld_image_count(); i++) {   // fishhook wants the slide
        if ((const void *)_dyld_get_image_header(i) != info.dli_fbase) continue;
        struct rebinding rebinding = {"mach_vm_map", (void *)imageMap, (void **)&gMachVmMap};
        rebind_symbols_image((void *)info.dli_fbase, _dyld_get_image_vmaddr_slide(i), &rebinding, 1);
        break;
    }
    if (gMachVmMap) return @"the game's image range stays held until the engine maps the game there";
    if (gImageHeld) vm_deallocate(mach_task_self(), gImageHeld, gImageSize);
    gImageHeld = 0;
    return @"the engine has no mach_vm_map import: the game's image range is given back now";
}

static vm_address_t gHeld;
static vm_size_t gHeldSize;
static char gInTheWay[600];   // what filled the hole at launch, when nothing could be held

void MadeiraEngineHoldPoolSpace(void) {
    for (vm_size_t size = 1024u << 20; size >= (640u << 20) && !gHeld; size -= 128u << 20)
        for (vm_address_t a = 0x119000000; a + size <= 0x180000000; a += 16u << 20) {
            vm_address_t at = a;   // FIXED: fails, never moves or replaces, where something already is
            if (vm_allocate(mach_task_self(), &at, size, VM_FLAGS_FIXED) == KERN_SUCCESS) { gHeld = at; gHeldSize = size; break; }
        }
    // A fence page just below, kept for good (already taken is fine too): a free gap there, under the pins' 16 MB, would
    // join the space when it is given back, and RX would start below 0x119000000 (seen on the iPad: rx 0x1180e0000).
    vm_address_t fence = gHeld - vm_page_size;
    if (gHeld) vm_allocate(mach_task_self(), &fence, vm_page_size, VM_FLAGS_FIXED);
    // No hole: what is in the way, for preparePool's report (address, size, tag, the image it belongs to).
    vm_address_t a = 0x119000000;
    vm_size_t size;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    size_t used = 0;
    while (!gHeld && used < sizeof gInTheWay - 80 && a < 0x180000000 &&
           vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &count) == KERN_SUCCESS &&
           a < 0x180000000) {
        Dl_info image = { 0 };
        dladdr((const void *)a, &image);
        const char *name = image.dli_fname ? strrchr(image.dli_fname, '/') : NULL;
        used += snprintf(gInTheWay + used, sizeof gInTheWay - used, " 0x%lx+%lu MB tag %u%s%s;", (unsigned long)a,
                         (unsigned long)(size >> 20), info.user_tag, name ? " " : "", name ? name + 1 : "");
        a += size;
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
    }
}

void MadeiraEngineReleasePoolSpace(void) {   // the fence page stays: it is one page
    if (gHeld) vm_deallocate(mach_task_self(), gHeld, gHeldSize);
    gHeld = 0;
}

static NSString *preparePool(size_t mb, vm_address_t image, vm_size_t imageSize) {
    for (int i = 0; i < 32; i++) {   // kept for the process's life, as Madeira does
        vm_address_t a = 0;
        if (vm_allocate(mach_task_self(), &a, 16u << 20, VM_FLAGS_ANYWHERE) != KERN_SUCCESS || a + (16u << 20) >= 0x119000000) break;
    }
    NSString *held = gHeld ? [NSString stringWithFormat:@"held %lu MB at 0x%lx from launch", (unsigned long)(gHeldSize >> 20), (unsigned long)gHeld]
                           : [NSString stringWithFormat:@"nothing held from launch: no 640 MB hole then; in the way:%s", gInTheWay];
    if (gHeld && gHeldSize >> 20 < mb) mb = (gHeldSize >> 20) - 128;   // a smaller piece was all there was
    if (gHeld) vm_deallocate(mach_task_self(), gHeld, gHeldSize);
    gHeld = 0;
    vm_address_t at = image;   // a fixed-base .exe's range: held from here until the engine maps the game (imageMap)
    if (imageSize && vm_allocate(mach_task_self(), &at, imageSize, VM_FLAGS_FIXED) == KERN_SUCCESS) { gImageHeld = image; gImageSize = imageSize; }
    if (imageSize) held = [held stringByAppendingFormat:@"; the game's fixed-base image 0x%lx+0x%lx %@", (unsigned long)image,
                           (unsigned long)imageSize, gImageHeld ? @"held" : @"was already taken"];
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
    NSString *dir = MadeiraEngineDirectory(), *dylib = [dir stringByAppendingPathComponent:@"MadeiraEngine.dylib"];   // WindowsKit.engineLibrary
    if (!dylib || ![NSFileManager.defaultManager fileExistsAtPath:dylib])   // before the pool: no address space pinned, no debugger waited for
        return [o stringByAppendingString:@"engine: Windows games are not set up (MacShack > Settings > Windows games)\n"];
    NSString *exe = request[@"run"], *game = request[@"game"];
    NSArray<NSString *> *screen = [request[@"screen"] ?: (game ? @"1408x648" : @"960x540") componentsSeparatedByString:@"x"];
    int screenW = screen.count == 2 ? screen[0].intValue : 960, screenH = screen.count == 2 ? screen[1].intValue : 540;
    vm_address_t image = 0; vm_size_t imageSize = 0;
    if (!FixedImageRange(request[@"gameExe"], &image, &imageSize)) imageSize = 0;
    size_t jitMB = [request[@"jitMB"] unsignedLongValue] ?: imageSize ? 512 : (game ? 896 : 384);   // Madeira's sizes: games, test programs
    NSString *pool = preparePool(jitMB, image, imageSize);
    [o appendFormat:@"engine: %@\n", pool];
    if (!getenv("WINE_IOS_JIT_RX")) return o;

    void *engine = dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);   // GLOBAL: DXMT dlsyms macdrv_functions
    if (!engine) return [o stringByAppendingFormat:@"engine: not loaded (%s)\n", dlerror()];
    int (*wineserverStart)(const char *) = dlsym(engine, "wineserver_start");
    int (*wineProcessStart)(const char *) = dlsym(engine, "wine_process_start");
    void (*setLayer)(CAMetalLayer *) = dlsym(engine, "madeira_display_set_layer");
    uint64_t (*presents)(void) = dlsym(engine, "madeira_frame_count") ?: dlsym(engine, "madeira_get_present_count");   // 0.2.0: + GL's
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
    if (gImageHeld) [o appendFormat:@"engine: %@\n", releaseImageOnItsMap((const void *)wineserverStart)];
    ShackEngineBundleRedirect((const void *)wineserverStart, dir);   // the engine's own files: Windows/engine, not Play's bundle
    [o appendFormat:@"engine: loaded %@\n", dylib.lastPathComponent];
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
    // What 0.2.0's app adds to every launch (MadeiraApp's init, configureLaunch, runWineFullSequence, LibraryBCD), unless
    // a game's .args set them: a program without a Steam identity of its own gets none (else the bridge gives every
    // program Thumper's, 356400); Windows.Gaming.Input sees the host pads; DXMT's census is throttled; a Unity IL2CPP game
    // (GameAssembly.dll beside its exe) suspends threads for real. Not the game-window overlay (#134): it attaches to the
    // key window, Play's, above its touch controls.
    if (!request[@"steamAppID"]) setenv("MADEIRA_NO_STEAM_IDENTITY", "1", 0);
    setenv("MADEIRA_WGI_HOST_PADS", "1", 0);
    setenv("DXMT_CENSUS_THROTTLE", "1", 0);
    setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0);
    setenv("MADEIRA_GAME_WINDOWS", "0", 0);
    NSString *il2cpp = [[request[@"gameExe"] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"GameAssembly.dll"];
    if (il2cpp && [NSFileManager.defaultManager fileExistsAtPath:il2cpp]) setenv("MADEIRA_REAL_SUSPEND", "1", 0);
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
    // Before the Windows process, as Madeira's app: the server ready (10 ms polls, 2 s at most: 0.2.0's
    // MADEIRA_FAST_SERVER_START), or 2 s.
    int (*serverRunning)(void) = dlsym(engine, "wineserver_is_running"), (*serverReady)(void) = dlsym(engine, "wineserver_is_ready");
    if (serverRunning && serverReady) for (int i = 0; i < 200 && serverRunning() && !serverReady(); i++) usleep(10000);
    else sleep(2);
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
