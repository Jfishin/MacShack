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

`make apis` generates the API databases from the macOS SDK and reads its version with `xcrun --show-sdk-version`, which
the Command Line Tools SDK does not answer: point `DEVELOPER_DIR` at a full Xcode. MacShack's databases come from the
macOS 27 SDK (Xcode 27, a beta at the time of writing). The `prebuilt-deps` download in the main README carries them
ready-made.

```sh
git submodule update --init vendor/AArchX
cd vendor/AArchX && git apply ../../prep/aarchx/macshack.patch
export DEVELOPER_DIR=<path to Xcode 27>.app/Contents/Developer
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

Other MacShack tools here:

- `check_steam_api.c`: an Intel game's own Steam API under AArchX, compared with Rosetta (Steam running; steps in its
  header, expect `steam api ok` and Rosetta's hash).
- `gaps.py "Game.app"`: the Intel counterpart of `shackprep.py gaps2`. It sorts every import of a game's x86_64 Mach-Os
  by what native mode would do with it (bridged, missing on the host, stub, not in the database); usage in its header.
- `smoke.sh [game...]`: runs the Intel games in its own list (Shovel Knight, Cyber Shadow, Gravity Circuit, Akane,
  Blasphemous, Hades) for 30 s each in native mode, from the Mac's Steam library (`STEAM_LIBRARY` names a second
  library's `steamapps/common`); logs in `build/aarchx-smoke/`. `SECS` changes the time; `DIAG=1` dumps guest threads
  and native stacks near the end.

What runs, Mac and device: [docs/compat-status.md](../../docs/compat-status.md).

## iOS port

AArchX builds and links for `arm64-apple-ios26.0` with no undefined symbols
(`include/ocerz/mach_vm_compat.h`: the iOS SDK's `mach_vm.h` is a bare `#error`, though
libsystem_kernel exports every function; `pthread_jit_write_protect_np` is a no-op there because the
arena is always the host's dual-mapped pool). `OCERZ_ARENA_GB=<n>` shrinks native mode's 256 GB
identity arena (tested at 4 and 16 GB). API databases and the guest C++ runtime are found through
`OCERZ_APIDB` and `OCERZ_GUEST_ROOT`, so they can live in the app bundle.

On iOS, AArchX also relies on: bundle identity through MacShack's hooks (`ocerz_bridge_set_host_symbol` ->
`ShackHookForGuestSymbol`), textual framework-path matching (no macOS framework exists on iOS to follow symlinks
through), guest `gl*` through `ShackGLGetProcAddress`, and `shims/AppKit/ShackGLLegacy.m` (fixed-function client
arrays, ARB shader objects, GLSL 1.x, desktop extension names).

Device test: copy the `.app` to `Documents/Staging`, write an `.args` with `--shack-env=SHACK_OPENGL=1` (GL games) and
`--shack-env=OCERZ_FPS=1` (frame counter), launch with `--prepare "<Name>"`, then `--launch "<Name>"`; the log is
`Documents/Logs/<exe>.log`, and `pymobiledevice3 developer dvt screenshot` takes a picture.

MacShack integration:

- `project.yml` target `Ocerz` builds `vendor/AArchX/src` as `libOcerz.dylib` (a separate dylib keeps the
  LGPL library replaceable), `main.c`'s `main` renamed `ocerz_main`; the embed phase copies
  `runtime/apis` and `runtime/guest` (and `apis32`/`guest32` for m32) to `MacShack.app/AArchX/` when they exist.
- `ShackInstaller`: an x86_64-only (or i386-only) main executable installs as `translate: x86_64` (or `i386`) with
  `requiresJIT`; nothing is prepared or signed, since AArchX reads the original Mach-Os as data and only runs code it
  generates into the pool. Its code root is its `Documents/Games` folder. (`test_installer.py` checks it.)
- `ShackLoader`: after `ShackJITPoolSetup`, a translated game runs `ocerz_main -native <exe> <args>` on
  the 64 MB `guest-main` thread with `OCERZ_JIT_POOL` (from `SHACK_JIT_POOL`), `OCERZ_ARENA_GB` (the largest of 16, 8
  or 4 GB that leaves 4 GB of address space free beside it), `OCERZ_STUB_MISSING=1` (an import no bridge covers becomes
  a logged stub), `OCERZ_APIDB`/`OCERZ_GUEST_ROOT` in the bundle, and `ocerz_bridge_set_host_open` answering each macOS
  install name with the library `+[ShackPrep hostLibraryForInstallName:]` maps it to (the same shim or
  iOS framework an arm64 game's load command is rewritten to).
- The pool is `--shack-jit-mb` (Intel games default to 512 MB, MonoKickstart games to 1 GB); raise it if AArchX logs
  "JIT code arena full". AArchX never reuses its pool: a full pool runs new code interpreted.

## Tips

- `OCERZ_BRIDGELOG_MATCH=open|stat` (words separated by `|`) prints each matching call's first argument as a string.
- Mono's `MONO_LOG_LEVEL=debug MONO_LOG_MASK=dll` (devicectl `--environment-variables`, or `--shack-env=`) shows each
  P/Invoke that fails to resolve.
- A slow Intel game: `--shack-env=OCERZ_PERFSTAT=1` names the ops left to the interpreter.
- Unity games on GL log compute and geometry shader errors (Subnautica's Waterscape) that can be harmless: on GL the
  game falls back to what it baked.
- More debugging variables and the bisection method: [docs/compat-playbook.md](../../docs/compat-playbook.md).

## 32-bit (i386) Mac games: m32 (experimental)

m32 runs i386-only Mac programs. No i386 game is confirmed playable on a device yet; Batman: Arkham Asylum (Feral)
launches. The code is `src/m32*.c` and `include/ocerz/m32*.h` in AArchX (inside `macshack.patch`), plus two hooks:
`main.c` routes an i386-only program to `m32_run`, and `ocerz_dyldapi_dispatch` hands a 32-bit cpu's trap to
`m32_trap`.

- The guest runs as i386 in a flat 4 GB window (`ocerz_mem_init(0, 4 GB)`); it never holds a host address. Host
  objects reach it as 8-byte handle cells at 0xE0000000-0xF0000000, guest objects with a host twin (CFSTR literals,
  CF-typed data it only takes the address of) as aliases (`m32_handle.c`).
- Imports from system libraries are addresses in the DYLDAPI trap window (`m32_bridge.c`); each export's two notations
  come from `runtime/apis32` (`make apis32`: `tools/sdkgen.sh --guest i386`, the SDK headers parsed as i386 10.14 beside
  arm64; read by `m32_db.c`). Guest-only classes: `s` C string, `P` one pointer written back, `W`/`V` one long written
  back, `Q` data whose layouts differ (needs a special). The generic crossing is `m32_cross.c`; hand-written ones are
  `m32_libsystem.c` (layouts, mmap, setjmp, signals, compiler-rt), `m32_stdio.c` (printf/scanf, heap, malloc zones,
  errno), `m32_thread.c` (pthreads with host twins, TLV), `m32_cf.c`, `m32_dyld.c` (dlopen, dyld APIs, images),
  `m32_gl.c` (mapped GL buffers, CGL), `m32_audio.c` (CoreAudio render callbacks: FMOD's output), `m32_zlib.c` (zlib
  and bzip2 streams). `m32_callback.c` lets host code call guest function pointers; `m32_leaf.c` serves hot small libc
  calls straight from the JIT, with no crossing.
- Objective-C 1 runtime for i386 guests: `m32_objc.c` (guest classes, proxies and paired host classes),
  `m32_objc_types.c` (type encodings), `m32_objc_exc.c` and `m32_catch.m` (setjmp-based `@try`, host NSExceptions
  rethrown into the guest), `m32_blocks.c` (blocks in both directions).
- C++ exceptions: `m32_unwind.c` is the Itanium two-phase unwinder over the guest images' `__eh_frame`, calling each
  frame's own personality routine in the guest.
- Guest dylibs load from `@executable_path`/`@loader_path`/`@rpath` and `runtime/guest32` (`OCERZ_GUEST32_ROOT`), with
  dyld-info or classic relocations (libgcc_s from MacPorts has no dyld info). Weak symbols coalesce to the first
  definition in load order, as dyld does.
- Heap: a dlmalloc mspace in the window (first segment `OCERZ_M32_HEAP_MB`, default 16 MB; more come as needed) until
  the program registers its own malloc zone (tcmalloc in Batman); then malloc and friends run the guest zone through
  generated i386 thunks and free goes by who owns the pointer.
- Guest GNU libstdc++: `prep/aarchx/guest32_libstdcxx.sh` (MacPorts GCC 15.2 i386 runtime, SHA-256 pinned).
- Diagnostics: `OCERZ_M32LOG=imports,calls,images` (also `keys`, `monitors`); `OCERZ_M32_KEEP_GOING=1` runs with
  unresolved imports.

Checks (Mac): `make apis32 && bash tests/m32/dbcheck.sh && make check-m32` (34 programs in `tests/m32`, each with an
`.expected` output, built with `clang -arch i386 -Wl,-ld_classic` against generated stub `.tbd`s; `tests/m32/build.sh`
uses Xcode 26 from `/Applications/Xcode.app`, whose linker still links i386), also with `OCERZ_NOJIT=1`.
