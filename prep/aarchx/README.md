# Intel (x86_64) Mac games: AArchX

`vendor/AArchX` is [mont127/AArchX](https://github.com/mont127/AArchX) (LGPL-2.1, binary `ocerz`),
an x86_64 Mach-O -> arm64 translator with its own loader, mini-dyld, JIT, Darwin syscalls and
Objective-C bridge. Only its **native mode** is usable on iOS: it synthesizes x86 stub images for
system libraries and bridges each call to the arm64 framework, so no Rosetta x86 shared cache is
needed. Cache mode maps Rosetta's cache and exists only on a Mac.

`macshack.patch` holds our changes to it, each marked `MacShack:`:

- a `data <export> 0` record exports an absolute zero (`_objc_empty_vtable`, Shovel Knight)
- sdkgen: OpenGL parses the libGL passes, `gl.h` and `gl3.h` (52 -> 1296 bridged), MediaToolbox library added,
  keymgr and `__cxa_finalize` signatures (old GCC C++ runtimes), AudioUnit library (old
  binaries import AudioToolbox's AudioUnit calls from it; FMOD)
- `objc_msgSend{,_stret,Super2,Super2_stret}_fixup`: legacy msgref ABI (Akane)
- lazy flat-namespace binds wait until all of the main executable's dependencies are loaded,
  as dyld resolves them on first call (LÖVE's love.framework imports Lua flat)
- `AudioUnitSetProperty` special: the render/input-callback struct's x86 proc is interned as a
  callback, since CoreAudio's I/O thread calls it natively (Unity's FMOD)
- a JIT lock still held where a fault recovery lands (`vm.c` sigsetjmp sites) is released and
  logged as `JITLOCK-RECOVER`: a fault inside `translate()` otherwise self-deadlocks the thread and
  every other thread behind it (Akane). `OCERZ_JITLOCKLOG` also prints where a recursive holder took it
- guest `pthread_create` gets a host stack of at least 4 MB (ocerz's translator runs on it; a Unity
  worker's small stack overflowed mid-translation)
- when AppKit first opens, registers the default `NSViewFixupNilFromMakeBackingLayer=YES`: AppKit
  judges by ocerz's (current) SDK, layer-backs every view, and traps on a nil `-makeBackingLayer`
  that old-SDK apps never hit (Unity's PlayerWindowView under OpenGL)
- dual-mapped JIT arena, as iOS requires: code runs from an executable mapping that is never
  writable, and every store into it goes through `a64_w`/`JW()` to a writable alias at a fixed offset.
  `OCERZ_JIT_POOL="<rx>,<rw>,<size>"` (hex) takes the host's pool (MacShack's `ShackJITPoolSetup`);
  `OCERZ_JIT_POOL_MB=<n>` builds one on the Mac, where a store that misses the alias faults exactly as
  it would on the phone
- `OCERZ_FPS=1` works in native mode: counts the `CGLFlushDrawable` stub and `-flushBuffer` sends
  (a native `NSOpenGLContext` swaps without reaching the stub)
- a message whose method the guest implemented jumps straight to the x86 IMP instead of crossing
  (Unity's `UnityPLCrashSignalHandler` passes x86 function pointers; also saves a crossing per
  guest-to-guest send)

## Build (Mac)

```sh
git submodule update --init vendor/AArchX
cd vendor/AArchX && git apply ../../prep/aarchx/macshack.patch
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer  # CLT SDK lacks SDKVersion
make -j && make apis && bash tools/build_guest_cxx.sh   # guest x86 libc++ in runtime/guest
bash ../../prep/aarchx/guest_libstdcxx.sh   # GNU libstdc++.6 (old Unity, Aragami, Blasphemous, Gungeon)
echo 'int ocerz_libstdcxx_shim;' > /tmp/stdcxx.c && G=runtime/guest/usr/lib
# libgcc_s.1 stand-in (FMOD links it, imports nothing): re-exports the guest libunwind
clang -arch x86_64 -dynamiclib -install_name /usr/lib/libgcc_s.1.dylib -nostdlib \
  -Wl,-reexport_library,$G/libunwind.1.dylib /tmp/stdcxx.c -o $G/libgcc_s.1.dylib
bash tests/run_dynamic_tests.sh && bash tests/run_native_tests.sh   # 134/134, 87/87
# MacShack checks: pthread_exit runs guest cleanup handlers; a non-PIE executable slides (scan rebase)
for t in check_cleanup.c check_nopie.m check_packmul.c check_l0loop.c check_builtins.c check_ssemisc.c check_dlsym_deps.c check_cfuuid.c check_printf_l.c check_mmx.c check_shiftcl.c; do clang -arch x86_64 -mmacosx-version-min=10.9 -framework Foundation -framework IOKit \
  -framework CoreFoundation -msse4.1 -Wl,-no_pie ../../prep/aarchx/$t -o /tmp/$t.x && ./ocerz -native /tmp/$t.x; done   # ran=11, nopie ok, packmul ok 48000, l0loop ok, builtins ok, ssemisc ok 90000, dlsym deps ok, cfuuid ok, printf_l ok, mmx ok 2dab7468d93168e0 (same as -no-jit), shiftcl ok ea85a0352a21c4f6
```

After editing `vendor/AArchX`, regenerate the committed patch (it must stay byte-identical to a fresh build's diff):

```sh
cd vendor/AArchX && git add -N . && git diff -- . ':!runtime' ':!tests/unit/bin' ':!ocerz' > ../../prep/aarchx/macshack.patch; git reset -q
```

`prep/aarchx/smoke.sh [game...]` runs local Steam Intel games for 30 s each in native mode; logs
in `build/aarchx-smoke/`.

## Status (2026-09-27, Mac, native mode)

| Game | Result |
|---|---|
| Cyber Shadow (Chowdren, OpenGL) | Title screen at **60 fps** on the M4 Max and **on the iPhone** (see iOS port). |
| Shovel Knight | Engine assertion (`ycAssert.cpp:101`) twice, then its int3. |
| Akane (Unity 2018.2) | **Renders at 55-61 fps** (dips to ~30 while loading). FMOD loads (AudioUnit database, libgcc_s stand-in, `__isfinitef` family); **sound plays**. Later scene crashes on NULL faults. |
| Gravity Circuit (LÖVE/LuaJIT) | Binds now; alignment fault (SIGBUS ADRALN) after 15 lines. |
| Hades | SIGBUS outside the guest arena after ~600 log lines. |
| Blasphemous (Unity 2017.4, non-PIE, Rewired) | Plays to its title at 60 fps on the iPhone (2026-09-28): GNU libstdc++ guest, non-PIE slide, and `ShackHID` keeping released IOHID queues alive (Rewired polls one after releasing it). |
| Enter the Gungeon | Imports real GNU libstdc++ (`guest_libstdcxx.sh` supplies it; all 65 imports resolve). Not run yet. |

## iOS port

AArchX builds and links for `arm64-apple-ios26.0` with no undefined symbols
(`include/ocerz/mach_vm_compat.h`: the iOS SDK's `mach_vm.h` is a bare `#error`, though
libsystem_kernel exports every function; `pthread_jit_write_protect_np` is a no-op there because the
arena is always the host's dual-mapped pool). `OCERZ_ARENA_GB=<n>` shrinks native mode's 256 GB
identity arena (tested at 4 and 16 GB). API databases and the guest C++ runtime are found through
`OCERZ_APIDB` and `OCERZ_GUEST_ROOT`, so they can live in the app bundle.

**iPhone 17 Pro Max, 2026-09-27: Cyber Shadow runs its title screen at 60 fps** (59.7-60.9, its cap;
sound bank 11 s vs 4 s on an M4 Max). Screenshot: logo drawn through the GL shim; the game then waits for
input. What it took on the device, beyond the Mac work: bundle identity through MacShack's hooks
(`ocerz_bridge_set_host_symbol` -> `ShackHookForGuestSymbol`), textual framework-path matching (no macOS
framework exists on iOS to follow symlinks through), guest `gl*` through `ShackGLGetProcAddress`, and
`shims/AppKit/ShackGLLegacy.m` (fixed-function client arrays, ARB shader objects, GLSL 1.x, desktop
extension names). Device test: copy the .app to `Documents/Staging`, `.args` with
`--shack-env=SHACK_OPENGL=1` (GL games) and `--shack-env=OCERZ_FPS=1` (frame counter), `--prepare`,
`--launch`, log in `Documents/Logs/<exe>.log`; `pymobiledevice3 developer dvt screenshot` for a picture.

MacShack integration:

- `project.yml` target `Ocerz` builds `vendor/AArchX/src` as `libOcerz.dylib` (a separate dylib keeps the
  LGPL library replaceable), `main.c`'s `main` renamed `ocerz_main`; the embed phase copies
  `runtime/apis` and `runtime/guest` to `MacShack.app/AArchX/` when they have been built on the Mac.
- `ShackInstaller`: an x86_64-only main executable installs as `translate: x86_64` with `requiresJIT`;
  nothing is prepared or signed, since AArchX reads the original Mach-Os as data and only runs code it
  generates into the pool. Its code root is its `Documents/Games` folder. (`test_installer.py` checks it.)
- `ShackLoader`: after `ShackJITPoolSetup`, a translated game runs `ocerz_main -native <exe> <args>` on
  the 64 MB `guest-main` thread with `OCERZ_JIT_POOL` (from `SHACK_JIT_POOL`), `OCERZ_ARENA_GB=16`,
  `OCERZ_APIDB`/`OCERZ_GUEST_ROOT` in the bundle, and `ocerz_bridge_set_host_open` answering each macOS
  install name with the library `+[ShackPrep hostLibraryForInstallName:]` maps it to (the same shim or
  iOS framework an arm64 game's load command is rewritten to).
- The pool is `--shack-jit-mb` (default 128 MB); raise it if AArchX logs "JIT code arena full".

## Device notes (2026-09-27, iPhone)

- Aragami (Unity 2017.2, non-PIE, GNU libstdc++): loads, slides, starts Mono; then exits because it ships
  only desktop-GL shaders (`-force-metal`: "not built from editor") and the CGL shim is a stub. Needs CGL on
  ShackGL plus GLSL 4.10 core → ES 3.00. Unity games with Metal shaders get `-force-metal` automatically.
- Akane: skipping the intro ran Mono's Boehm `GC_thread_exit_proc` natively (guest `pthread_cleanup_push`
  records sit on the host thread's `__cleanup_stack`); the `pthread_exit` special now runs them as guest code.
- Hades (Game.macOS.app, Metal via The Forge): runs at 60 fps. It was ~1 fps until packuswb/pmaddubsw/pmulhw
  (its video decoder, ~8 M/s) were inlined as NEON instead of running in exec_one. Diagnose such stalls with
  `--shack-env=OCERZ_PERFSTAT=1` (SLOWOP table every 15 s); remaining slow ops there: pshuflw, cvttps2dq, cmpps,
  rcpps, movmskpd.
- Celeste (MonoKickstart, x86 Mono JIT, FNA3D on GL, FMOD 1.10): boots to the menus and plays with saves.
  Needed: GSS API database, leaf-name dlopen through LC_RPATH (dyld order), x86_64 gbe_fork as its Steam API
  (it quits on "Steam not found!"), thread_get_state flavor 5, base-vertex draws in ShackGL. Audio is silent:
  Audio: FMOD 1.10's multiband EQ blew up to NaN because the fused dec/inc+jcc emitters dropped scalar
  results carried around a loop with a fixed l0 mapping; they now defer to emit_jcc (check_l0loop.c).
  Celeste's x86 Mono JIT fills ~150 MB of translations in its first 20 s and ~1 MB/s after: MonoKickstart
  games get a 1 GB pool (~18 s to prepare). AArchX never reuses its pool; each block carries a ~50-word
  prologue and 50-130-word epilogue, so sharing those (or flushing when full) is the real fix.
- Bisecting a translation bug: `OCERZ_ARENA_AT=0x9000000000` pins guest addresses, then
  `OCERZ_INTERP_LO/HI` interprets a range; a range that fixes the output holds the bad block
  (`OCERZ_JITDIS=<file> OCERZ_JITDIS_LO/HI` dumps its arm64; Homebrew llvm-mc disassembles). Rebuild with
  `rm src/jit.o` first: macOS make compares whole seconds.
- Bridge traces (`OCERZ_BRIDGELOG_MATCH=open|stat`, words separated by `|`) print the first argument as a string.
- Subnautica (Unity 2019, GLSL 150 only): **plays** (2026-09-28) on ShackGL's CGL. Its DXT textures (black: iOS has
  no S3TC) are re-encoded as ASTC; the loading screen's mip upload reads past its buffer into a guard page (padded in
  ShackGL); a guest `abort()` now `_exit`s (it waited on threads Boehm had stopped, and froze). The Waterscape
  compute/geometry shader errors are harmless: on GL the game uses its baked water. Underwater renders black (open).
  Aragami (Unity 2017, GL only, -force-glcore via AutoConfig): "Press Any Button". Both needed Carbon's
  SetSystemUIMode / Event Manager stubs and the self-contained x86 gbe.
- emit_sse_misc inlines movshdup/movsldup, pshuflw/pshufhw, movmskps/pd, cmpps/pd (0-7), cvttps2dq (x86's
  0x80000000 for out of range and NaN), rcpps/rsqrtps (estimate + one Newton step, within x86's 1.5*2^-12),
  psrldq/pslldq, haddps/pd, blendps/pd. Hades's exec_one share: 0.29% -> 0.08% of instructions. Left: imul with
  a memory operand, shifts by cl / of memory, ptest (flag-setting forms in the integer core).
- Cuphead (Unity 2017.4, Rewired input, CSteamworks): Rewired's `dlopen(".../CoreFoundation.framework/CoreFoundation")`
  returned NULL: iOS's framework folders are flat, so realpath kept the unversioned name no stub carries. The API-DB
  install-name match now runs before realpath (`tests/unit/test_canon.c`, part of `make unit`). Its old Steam API
  (`SteamClient017`) then needed gbe's `steam_interfaces.txt`, which the installer writes.
  Its pad needed two more: Rewired imports CoreText by its old path under ApplicationServices (`ApplicationServices.framework/
  Frameworks/CoreText.framework/CoreText`; a moved sub-framework now matches the top-level one, as macOS's symlink does), and asks
  that handle for CoreFoundation's `CFStringGetTypeID` (a virtual system library's handle now also reaches the other
  system libraries, standing in for its dependents; `check_dlsym_deps.c`). Mono's `MONO_LOG_LEVEL=debug`
  `MONO_LOG_MASK=dll` (devicectl `--environment-variables`) shows each P/Invoke that fails to resolve.


## 32-bit (i386) Mac games: m32 (experimental, 2026-09-30)

The code is `src/m32*.c` and `include/ocerz/m32*.h` in AArchX (inside `macshack.patch`), plus two hooks: `main.c`
routes an i386-only program to `m32_run`, and `ocerz_dyldapi_dispatch` hands a 32-bit cpu's trap to `m32_trap`.

- The guest runs as i386 in a flat 4 GB window (`ocerz_mem_init(0, 4 GB)`); it never holds a host address. Host
  objects reach it as 8-byte handle cells at 0xE0000000-0xF0000000, guest objects with a host twin (CFSTR literals,
  CF-typed data it only takes the address of) as aliases (`m32_handle.c`).
- Imports from system libraries are addresses in the DYLDAPI trap window; each export's two notations come from
  `runtime/apis32` (`make apis32`: `tools/sdkgen.sh --guest i386`, the SDK headers parsed as i386 10.14 beside arm64).
  Guest-only classes: `s` C string, `P` one pointer written back, `W`/`V` one long written back, `Q` data whose
  layouts differ (needs a special). The generic crossing is `m32_cross.c`; hand-written ones are `m32_libsystem.c`
  (layouts, mmap, setjmp, signals, compiler-rt), `m32_stdio.c` (printf/scanf, heap, malloc zones, errno),
  `m32_thread.c` (pthreads with host twins, TLV), `m32_cf.c`, `m32_dyld.c` (dlopen, dyld APIs, images),
  `m32_gl.c` (mapped GL buffers, CGL), `m32_audio.c` (CoreAudio render callbacks: FMOD's output).
- Guest dylibs load from `@executable_path`/`@loader_path`/`@rpath` and `runtime/guest32` (`OCERZ_GUEST32_ROOT`), with
  dyld-info or classic relocations (libgcc_s from MacPorts has no dyld info). Weak symbols coalesce to the first
  definition in load order, as dyld does.
- Heap: a dlmalloc mspace in the window (`OCERZ_M32_HEAP_MB`, default 1024) until the program registers its own
  malloc zone (tcmalloc in Batman); then malloc and friends run the guest zone through generated i386 thunks and
  free goes by who owns the pointer.
- Guest GNU libstdc++: `prep/aarchx/guest32_libstdcxx.sh` (MacPorts GCC 15.2 i386 runtime, SHA-256 pinned).
- Diagnostics: `OCERZ_M32LOG=imports,calls,images`; `OCERZ_M32_KEEP_GOING=1` runs with unresolved imports.

Checks (Mac): `make apis32 && bash tests/m32/dbcheck.sh && make check-m32` (13 programs in `tests/m32`, built with
`clang -arch i386 -Wl,-ld_classic` against generated stub `.tbd`s), also with `OCERZ_NOJIT=1`.

Batman (Mac, `ocerz -native` on the phone's copy): loads (1,641 imports, 5 guest dylibs), runs its and libstdc++'s
initializers and ~134 M guest instructions, registers tcmalloc, then calls through a handle (an ObjC IMP from
`method_setImplementation`): the Objective-C 1 runtime (M2) is next. Open: C++ exceptions (GCC's i386 unwinder reads
DWARF via keymgr only; Apple-linked games need LLVM libunwind for i386), the JIT arena filling at ~88 KB per i386
block (1 GB for 11.8k blocks), `AppKit`/`QuartzCore`/`AVFoundation` i386 header parse errors, x87 in the JIT.
