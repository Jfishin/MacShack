# Compatibility playbook

How to take a macOS game that does not run and find out why. Everything here was learned bringing up the games in
[compat-status.md](compat-status.md). Verify a claim against the code before relying on it: these notes are dated, the
code is not.

## Ground rules

- **Bring your own games.** MacShack runs games you own. No game content is in this repo, and none should be committed.
- **One game per process.** Images cannot be unloaded and Unity games share install names. Quitting a game returns to
  MacShack; starting another game then relaunches the app (`pendingLaunch` in `host/AppModel.swift`).
- **Every host install invalidates prepared games.** The manifest pins the host executable hash. Follow each install
  with `--prepare "<Name>"` (or **Prepare again**) per game. Install records are kept per game in
  `Library/Guests/<Name>/current.plist`.
- **Know which build is on the device before debugging.** A game installed by an older build keeps its old install
  record, and old hosts lack later fixes. Compare the first lines of the game log with a game that is known to work
  (`guest preferences:`, JIT pool size, frame cap line).
- **Never pass `--remove-existing-content` to `devicectl device copy to`.** It wiped an app's whole data container.
  Read a file back after copying it; do not force an overwrite.
- **Read the log before assuming a game's configuration.** One game's first patch assumed a platform setting the game
  did not use and changed nothing; the log named the real one.

## Where to look

| Log | Path (in the app's data container) | Holds |
|---|---|---|
| Game host log | `Documents/Logs/<exe>.log`, named after the game's executable | A game started from Local Games: MacShack, shim and loader lines, until the game redirects stdout |
| Steam client log | `Documents/Logs/steam_osx.log` | Steam, and the games it starts from Big Picture (they run in its process) |
| Unity player log | `Library/Logs/Unity/Player.log` or `Library/Logs/<Company>/<Product>/Player.log` | The rest, once Unity 5+ reopens stdout (AArchX `ocerz:` lines land here too) |
| Prepare | `Documents/Logs/preparation.log`, `Library/Guests/<Name>/current.plist` | What the installer did |
| Steam setup | `Documents/Logs/steam-setup.log` | Download, unpacking and prepare of Valve's Steam client |
| JIT helper | `Documents/Logs/jit-helper.log` | Built-in JIT extension |

```sh
xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer --domain-identifier <bundle-id> \
  --source Documents/Logs/<exe>.log --destination build/<exe>.log
pymobiledevice3 developer dvt screenshot build/shot.png    # works while the phone is unlocked
pymobiledevice3 crash pull build/crashes                   # crash reports name the libraries the ASI hides
```

Every 10 s the host logs `mem available … N drawables in 10 s`, and once a minute `pacing cap C: … refreshes on glass …`.
**No `pacing` line at all means no frame reached the screen.**

## Triage: symptom to first look

| Symptom | Look at first |
|---|---|
| Installed, nothing happens, no game log | `preparation.log`, the status shown in Local Games, `current.plist` exists? "MacShack or its development profile changed…" means re-prepare |
| Exits at once, no log | `pymobiledevice3 crash pull`. A silent `_Exit(1)` in Unreal: attach lldb on a `--start-stopped` launch and break on `RequestEngineExit` |
| `ocerz: fatal: …` (Intel games) | AArchX loader. `no host base accepts the … shadow block` = a build without the non-PIE slide |
| `ocerz: BRIDGE-FAULT` | A shim marshalled a crossing wrong, or a shim object was freed while the guest still held it. Trace with `OCERZ_BRIDGELOG_MATCH` |
| Frames present (pacing lines) but the screen is black | The game is half-loaded. Find the first exception after the load starts (Unity: `Ups! There was an unhandled exception`, Steamworks errors). A managed exception inside a coroutine is silent |
| `SteamAPI_Init() failed; ipcserver init failed` | Valve's library ran with no Steam client behind it: the game was started from Local Games. Start it from Big Picture (see "Steam inside the game") |
| Black boot, rendering fine, no `pacing` line (Unity) | Known open issue: rotate the phone |
| Killed for memory | `mem available` line; texture quality settings; the per-game **Memory swap** toggle (off by default, costs frame rate) |
| Low fps | `--shack-watch` stacks, `--shack-gputrace`, and for Intel games `OCERZ_PERFSTAT=1` (prints a table of interpreted x86 ops every 15 s) |
| `[ShackTrapJIT] unhandled instruction` | A store the trap decoder does not replay (`host/ShackTrapJIT.c`) |
| Missing symbol or selector at load | `prep/shackprep.py gaps2` (below); for Intel games `prep/aarchx/gaps.py` |

## Launch arguments

A game's `.args` file (`Documents/Games/<Name>.args`) holds one argument per line. The game gets the ordinary ones. The
host consumes these:

- `--shack-env=NAME=VALUE` sets an environment variable before the game starts. Examples: `SHACK_OPENGL=1` (desktop GL on
  ES), `SHACK_APP_THREAD=main` (Unreal), `SHACK_HID_GAMEPAD=0`, `SHACK_RENDER_SCALE`, and any `OCERZ_*` below.
- `--shack-watch`: stats every 10 s, stack samples and a frame PNG every minute (hitches: leave it off normally).
- `--shack-gputrace[=S]`: Metal capture at launch; copy an empty file to `Documents/Logs/gputrace.request` to capture one frame.
- `--shack-jit-mb=N`: JIT pool size, 16 to 1024 MB (default 128 MB; Intel games 512 MB, MonoKickstart games 1 GB).
- `-fpsCap N`, `-force-metal`, `-force-glcore` (Unity graphics device; Intel Unity games get `-force-metal` automatically).
- From the Mac, `devicectl … process launch <bundle id> --launch "<Name>"` and `--prepare "<Name>"`.

Remove diagnostic flags when done.

## Device cycle

About 10 minutes with a build: build Release, `devicectl device install app`, launch with `--prepare "<Name>"` and wait
about 30 s, copy the `.args` with plain `devicectl device copy to` (never `--remove-existing-content`) and read it back
with `copy from` and `cmp`, launch with `--launch "<Name>"`, wait, then `copy from` `Documents/Logs/<exe>.log`. Stop the
game afterwards (`devicectl device process terminate`) when it spins. For a large folder (a whole game), use
`prep/devsync.py` ([CONTRIBUTING.md](../CONTRIBUTING.md)).

## Bringing up a native arm64 game

1. Install it from Steam Big Picture (MacShack prepares it when Steam starts it), or copy the unmodified `<Name>.app`
   into `Documents/Staging` and tap **Prepare** in Local Games. Preparing patches the Mach-Os (platform, main executable
   to dylib, macOS frameworks to `libShack*`), signs them on the device and installs them under
   `Library/Guests/<Name>/<generation>`. The game's data stays untouched (`Documents/Games`, or Steam's library).
2. **Find link gaps on the Mac before the phone.** No device needed:
   ```sh
   python3 prep/shackprep.py gaps2 "/path/to/Game.app" --shims build/Build/Products/Release-iphoneos/MacShack.app/Frameworks
   ```
   Target: `hard 0`. Every hard gap is a symbol some game binary imports that no shim or iOS framework provides.
   `prep/compat_audit/compat_audit.py` goes further: it also lists the Objective-C selectors a game sends that neither
   iOS nor the shims answer (hard, or soft where a shim logs and returns 0), checks Metal API iOS lacks, and guesses the
   engine. Usage is in its header.
3. Launch; read the log; fix the first failure; repeat. Common kinds and where the fix lives:
   - macOS-only API the game calls: add it to the matching shim under `shims/<Framework>/` (AppKit on UIKit is the
     big one). A shim that fakes a system object must expose exactly the real object's properties, run loop sources and
     initial values. Games probe them and trust the answer (Unity's HID `DeviceUsage` crash).
   - the game asks the app about itself (bundle path, executable, computer name, preferences): identity hooks in
     `host/ShackHooks.m`. Capture host values at load, because after launch `NSBundle.mainBundle` answers for the game.
   - Metal behaviour desktop GPUs allow and iOS does not: `host/ShackMetal.m` (heap types, `didModifyRange:`, storage
     modes, budget). Hooks of `new*`/`copy*` selectors must return +1 untouched (`RETAINED`), or a pool-less game thread
     leaks everything.
   - engine detection: Unreal is detected by the project folder beside `Contents/UE4/Engine`, not the executable name.
   - Mac games `dlopen` with the wrong case; the dlopen hook has a case-insensitive fallback.
4. Game-specific byte patches are a last resort: `prep/patch_<game>_*.py`, verify the original bytes, idempotent (run
   twice: `patched N site(s)`, then `already patched`).

Unity Mono games also need JIT. MacShack starts its `MacShackJIT` extension (StikJIT, pairing file, LocalDevVPN) before
the game; the game's own Mono is adapted by `host/ShackTrapJIT.c`, or a catalog Mono rebuilt with
`prep/unity-mono/dualmap.patch` is used when the revision matches (`prep/unity-mono/README.md`). Never write to the
executable side of the pool directly: on iOS 26 and later (TXM devices) a mapping the debugger made executable cannot be
made writable and executable again, so code is written through the RW alias.

## Bringing up an Intel (x86_64) game

Intel games run under AArchX native mode (`vendor/AArchX`, our patch `prep/aarchx/macshack.patch`, built as
`libOcerz.dylib`). Nothing of the game is prepared or signed: AArchX reads the x86 Mach-Os as data and runs code it
generates into the JIT pool. System libraries are synthesized x86 stubs that call into the same shims an arm64 game uses.

**You can bring an Intel game up on the Mac first.** Build AArchX (`prep/aarchx/README.md`), then run the game with
`vendor/AArchX/ocerz -native <exe>` from its `Contents/MacOS` folder. `prep/aarchx/smoke.sh [game...]` runs the games in its own list for 30 s each in
native mode, from the Mac's Steam library (`STEAM_LIBRARY` names a second library's `steamapps/common`). Faults that reproduce on the Mac are cheaper to fix there.
Only after that go to the phone.

AArchX debugging variables (set on the Mac, or with `--shack-env=` on the phone):

| Variable | Use |
|---|---|
| `OCERZ_BRIDGELOG_MATCH="IOHIDQueue\|CFRelease"` | Log arguments and result of every bridged call whose name contains a word. Found the Blasphemous queue bug |
| `OCERZ_FAULTLOG=1` | Thread, rip image and `[rsp]` at each fault |
| `OCERZ_PERFSTAT=1` | Table of ops that fall back to the interpreter |
| `OCERZ_JITDIS=<path>` | Write the generated arm64 code to `<path>.<pid>` (limit with `OCERZ_JITDIS_LO/HI`; disassemble with `llvm-mc`) |
| `OCERZ_BRIDGELOG=1` | Log every bridged crossing (very noisy; prefer `_MATCH`) |
| `OCERZ_ARENA_GB`, `OCERZ_JIT_POOL_MB` | Arena size; a self-made pool on the Mac, where a store that misses the RW alias faults as it would on the phone |
| `OCERZ_ARENA_AT=<addr>`, `OCERZ_INTERP_LO/HI` | Pin the arena so guest addresses repeat, then keep a range in the interpreter: bisects a JIT miscompile. More knobs are listed in the comment above `jit.c`'s includes |

More variables for tracing a guest that misbehaves after millions of instructions (all MacShack additions, marked in the patch):

| Variable | Use |
|---|---|
| `OCERZ_BRIDGELOG_MATCH` + `OCERZ_TRACE_CHAIN=1` | Each traced call also prints its guest caller and, with the chain, the frame-pointer chain: which guest function reads that file or calls that API. Lines end `from <ret>`; the third argument is printed too. **Not** combined with `OCERZ_BRIDGELOG`, which would log everything |
| `OCERZ_REGTRAP=a,b,...` (up to 64), `OCERZ_REGTRAP_DEREF=1`, `OCERZ_REGTRAP_BRIEF=1`, `OCERZ_REGTRAP_MEM=addr,...`, `OCERZ_REGTRAP_MAX=n`, `OCERZ_REGTRAP_DEREF_LEN=bytes` | Dump registers (or one line, or memory at fixed addresses) each time the guest reaches an address; `_MAX` stops after n hits in all, `_DEREF_LEN` sets how far `_DEREF` reads past each register (0x300 shows an object's fields). Needs that code interpreted: pair with `OCERZ_INTERP_LO/HI` (or `_REL_LO/HI`, `_REL2_LO/HI` for two ranges) |
| `OCERZ_REL_MODULE=<part of a dlopen path>` | Base of that image, taken at map time (before its initializers). Then `@0x1234` entries in `OCERZ_REGTRAP` and `OCERZ_INTERP_REL_LO/HI`, `OCERZ_INTERP_REL2_LO/HI` are offsets into it. **Use these**: the load base moves with other mappings, so absolute addresses from one run miss in the next |
| `OCERZ_DWATCH=<addr>` (+ `OCERZ_DWATCH_ARM=<rip>` or `_ARMVAL=<qword>` with `_ARMN=<nth>`) | After arming, reports the interpreted instruction after which the 8 bytes at `addr` changed, with a frame chain. Interpreted code only; `OCERZ_WATCH` (JIT stores) crashes the launcher in its slow path |
| `OCERZ_EXITLOG=1` | Return address and frame chain of every guest `exit` |
| `OCERZ_DLOPENLOG=1`, `OCERZ_IMGLOG=1` | Every guest `dlopen` with its result (the result is the image base) |

**Rosetta is the ground truth on the Mac.** `arch -x86_64 ./prog` runs an x86_64 program on real (translated) x86
semantics, so a suspect function can be checked against it. Extract the function's bytes from the game (`otool -l` for
the `__text` file offset, then `.byte` lines in a `.S`), call it from a small C driver with random inputs, and run the
driver under Rosetta, under `ocerz -native` and under `OCERZ_NOJIT=1` (interpreter): two of the three agreeing names the
wrong one. Then sweep the `OCERZ_NO_*` knobs one at a time to see which JIT feature matters (`NO_JCCFUSE`, `NO_SIDEFUSE`,
`NO_SUPERBLOCK`, `NO_REGFLAGS`, ...), and dump `OCERZ_JITDIS=<path>` for the block (assemble the `.inst` words with clang
and read them with `llvm-objdump`). For example, a hash function in BioShock's gameswf disagreed with Rosetta and the
interpreter because compare-and-branch fusion crossed an instruction that rewrote the compare's own address register
(`side_gap_fuse_ok`). Keep a harness that reproduces with the game's bytes (uncommitted) rather than a synthetic test
that cannot fail.

Interpreting the whole game is too slow to reach the failure (minutes for the first 100 million instructions), so interpret
the smallest range that matters. `OCERZ_INTERP_REL_*` on a range that changes the outcome is a JIT-versus-interpreter
bisection; a script that reruns with halved ranges finishes in a few minutes.

Symbolizing a guest address: the main image of a non-PIE executable linked at `0x100000000` is slid to the arena base
(`0x7000000000`), so subtract `0x6f00000000` and look it up in the game binary.

Recurring causes, in the order they appeared:

- **Old GNU libstdc++.** Games built with GCC's runtime need the x86 GNU libstdc++ guest (`prep/aarchx/guest_libstdcxx.sh`,
  MacPorts' build, checksum pinned). Not committed.
- **Non-PIE executables** slide into the arena and their absolute pointers are rebased by a scan (`dyld.c`); the 12 GB low
  shadow is unusable on iOS.
- **Unity ≤ 2019 on GL.** iOS has no CGL. Unity gets `-force-metal`; GL-only projects use the CGL layer on `ShackGL`
  (`shims/AppKit/ShackGL*.m`, desktop GL translated to ES 3: GLSL 330 to 300 es, BC/DXT textures re-encoded to ASTC).
- **Rewired** reads pads only through IOHIDQueue events, re-finds them through the IORegistry, and maps the 2019 Xbox
  identity as unknown before 2019: the loader gives Rewired games the 2016 Xbox identity (`SHACK_HID_PAD=xbox2016`). It
  also stops, releases and then polls a queue once more; the shim's queues must outlive their release.
- **Translated code is CPU-bound.** SSE integer ops left to the interpreter held Hades' video decoder to about 1 fps;
  emitting them inline (`emit_sse_packmul`) gave a locked 60. `OCERZ_PERFSTAT=1` names the ops. A pool that fills logs
  "JIT code arena full": raise `--shack-jit-mb`.
- **Audio through FMOD** depends on exact SSE semantics; compare a Rosetta run to an ocerz run of the game's own libfmod
  in a Mac harness when output is silent (Celeste).

### Editing AArchX

`vendor/AArchX` is a submodule pinned to upstream. Our changes live only as `prep/aarchx/macshack.patch`, each hunk
marked `MacShack:`. After editing the submodule tree, regenerate the patch with exactly this and commit the patch:

```sh
cd vendor/AArchX && git add -N . && git diff -- . ':!runtime' ':!tests/unit/bin' ':!ocerz' > ../../prep/aarchx/macshack.patch; git reset -q
```

A fresh checkout builds and passes the AArchX tests from that patch alone; regenerating after a from-scratch build
reproduces the committed file byte for byte. After editing sources, `touch src/*.c` before `make`,
and `rm src/jit.o` after a quick edit to `jit.c` (macOS `make` compares whole seconds).

### Reading an Intel game's crash or hang on the phone

- `OCERZ_DLOPENLOG=1` prints each bundle's load address (`DLOPEN ... -> 0x7042814000`). It stays put for identical
  `.args` and moves when other mappings or the interpreter ranges change, so read it in the same run. Guest `rip` minus
  that base is an offset into the bundle: `llvm-objdump -d` the x86_64 file. Symbols are often sparse; identify code by
  the strings it uses. Main-image file addresses are guest addresses minus the actual main-image base plus
  `0x100000000`; do not reuse one run's slide in another.
- `--shack-watch` makes AArchX dump every guest thread (`THREADDUMP`, with a guest backtrace) every 10 s: a thread at
  `stat` is working, one at `psynch_cvwait` is waiting.
- `OCERZ_BRIDGELOG_MATCH=_stat|_fopen` piped through `sed 's/0x[0-9a-f]*//g' | sort | uniq -c` shows which calls
  dominate. Run such snippets in bash: zsh does not word-split an unquoted `$VAR` of options.
- On the Mac only, `OCERZ_ARENA_AT` can pin the arena so addresses repeat. Do not pin arenas on iOS: a `MAP_FIXED`
  reservation can collide with the JIT alias.

### Feral Interactive ports

Where BioShock Remastered stands is in [compat-status.md](compat-status.md). What a Feral launcher needs:

- **It checks, maps and calls its Steam library itself.** The launcher reads `Contents/Frameworks/libsteam_api.dylib`,
  compares `XXH64(file, 0)` to a constant, maps it with its own Mach-O loader (a fat file with an x86_64 slice; flags
  only `NOUNDEFS|DYLDLINK|TWOLEVEL|WEAK_DEFINES|BINDS_TO_WEAK|NO_REEXPORTED_DYLIBS`; no `LC_BUILD_VERSION`, no chained
  fixups, no thread-locals, no reexports), and calls each function at Valve's export address. Whether that works with
  Valve's Steam from Big Picture is untested.
- **The pre-game options window is an HTML page in the legacy `WebView`**, which iOS does not have. `-no-feral-options`
  in `.args` skips it (AutoConfig adds it for BioShock).
- **Rendering and presentation can differ.** Feral's IndirectX can render with Metal and present through GL
  (`MetalUseGLToSwap`), so GL contexts or a GL swap counter do not tell which backend renders. The shim rejects
  `CGLTexImageIOSurface2D`, so that interop swap path is unsupported. `SHACK_OPENGL=1` enables the GL API Feral probes at
  startup; it does not force the main renderer to GL. Change Feral's registry settings one value at a time, after a
  backup, and read the file back after copying it.
- **Data folder:** the launcher wants its data folder beside the `.app` and in `~/Library/Application Support/Feral
  Interactive/<name>`. MacShack does not create these: link them by hand, with relative symlinks (an absolute one
  dangles after every install, because the container UUID changes). It asks for the folder in **HFS style**, so
  `CFURLCopyFileSystemPath` and `CFURLCreateWithFileSystemPath[RelativeToBase]` are hooked in both directions
  (`host/ShackHooks.m`).
- **Its crash reporter (PLCrashReporter in QuincyKit) hides AArchX's own crash report.** A guest fault shows up as a
  `plcrash` file write, `thread_get_state ... flavor 7` and `exit(72)`. Add `--shack-env=OCERZ_FAULTLOG=1` and
  `--shack-env=OCERZ_SIGTRACE=1` to see the fault.
- **The game bundle binds to the launcher's own Windows-compat exports** (Sleep, GetTickCount, `SteamAPI_*` ...) with the
  main-executable ordinal: AArchX searches the main executable first for those, as dyld does.
- **Feral's threads.** `WinMain` is the game thread; the launcher keeps its own task queues (`dispatch_semaphore` polling
  with a timeout of 0, so a thread waiting for the main thread burns CPU) and wakes the main thread with an
  NSApplicationDefined event that `nextEventMatchingMask:` must return: the shim queues posted events as soon as a game
  pumps its own loop. Engine pieces seen in BioShock: FMOD Ex 4.44 (CoreAudio output and a CD-DA codec), gameswf (Flash
  UI), vpx decode threads (intro movies), `Feral3DWarmer` (shader warm-up), `Swap` (the GL presentation thread).
- **A function that returns a code address needs a thunk.** OpenAL's `alcGetProcAddress` answered a host arm64 address
  that the guest jumped to as x86. `host/ShackHooks.m` (`AudioProcThunk`) answers `ocerz_bridge_native_thunk(fn, name,
  notation)` for the names Feral looks up and NULL for the rest; use the same for any other `*GetProcAddress`-style call.

## Steam inside the game

Games started from the Steam client inside MacShack (Big Picture) get Valve's real Steam API: the host gives the game a
private `steamclient`, the environment Steam launched it with, and the in-process ipcserver
([prep/steam-onehost/README.md](../prep/steam-onehost/README.md) has the Mac prototype). This holds for native and Intel
games.

Games started from Local Games have no Steam client behind them; their `SteamAPI_Init` fails. Games that tolerate that
run without Steam features; games that require Steam quit.

### How it works for Intel games

The same way an Intel game on an Apple silicon Mac does it under Rosetta. Valve's `steamclient.dylib`, `libtier0_s`,
`libvstdlib_s`, `libaudio` and `crashhandler` are universal (x86_64 + arm64), so the game's own x86 `libsteam_api` loads
their x86_64 slices from Steam's folder, translated like the game, and they talk to the arm64 Steam over Mach, SysV
semaphores and shared memory. No C++ interface crosses architectures, only system calls. On the Mac,
`prep/aarchx/check_steam_api.c` shows AArchX matching Rosetta for both libsteam_api generations (an SDK with
`SteamAPI_Init`, and 1.58+ with `SteamAPI_InitFlat`), also with a dual-mapped JIT pool and a reduced arena like the
phone's (MacShack picks the largest of 16, 8 or 4 GB that leaves 4 GB free beside it): all 952 imports of the x86
steamclient resolve, no stubs. The calls that cross to the host in a session: `bootstrap_look_up`
(com.valvesoftware.steam.ipctool), `semget`/`semctl`, `mach_msg`, `kevent`, `kill(pid, 0)`, `sysctl`, `getpid`, `getenv`
(SteamAppId and friends), one loopback `connect`.

On iOS they get the answers Steam's own images get (libShackSteamClient's in-process IPC, the game's pid and launch
environment): AArchX resolves an ordinary bridged call through `ShackHookForGuestSymbol` (dlsym, which fishhook never
changes), which asks `translatedGameSymbol` in `host/ShackSteamClient.m` while a translated game Steam started runs; its
own handlers (`sem_open`, `shm_open`, `semctl`, `popen`) call libOcerz's imports, rebound at the game's start. The log
shows `[SteamClient] the Intel game's <call>: Steam's answer` and Valve's `[S_API] SteamAPI_Init(): Loaded '<path>'`.
Celeste started from Big Picture connects (Steam logs `Game process updated` for its app ID) and plays. The device's
Steam folder must keep the x86_64 slices (Steam set up by MacShack does; a Steam copied by hand and thinned to arm64
does not). i386 games have no such path: Valve ships no 32-bit steamclient.

## Conventions

- Changes to other projects' code live as patches under `prep/` (`prep/aarchx/macshack.patch`, `prep/zsign-*.patch`,
  `prep/unity-mono/dualmap.patch`); each AArchX change is marked `MacShack:`.
- Put a Mac-runnable check beside new logic (`host/probe/test_*`). [CONTRIBUTING.md](../CONTRIBUTING.md) lists the
  commands.
- Update [compat-status.md](compat-status.md) when a game's state changes, with the date.
- One commit per finding, message says what broke and why the change fixes it.
- Ask before disturbing a shared device: launching or preparing other games kills whatever the owner has open.
