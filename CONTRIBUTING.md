# Contributing to MacShack

Most changes can be checked on a Mac before they go near a device. Put a Mac-runnable check beside new logic
(`host/probe/test_*`, or a `check_*` program for AArchX) and run the checks for the code you touched. Building and
installing the app is described in [README.md](README.md); debugging a game is described in
[docs/compat-playbook.md](docs/compat-playbook.md).

## Device safety

- **Never pass `--remove-existing-content` to `xcrun devicectl device copy to` (or any devicectl command).** It wipes
  the app's entire data container on the device (every game, save, prepared build, log and setting), not just the file
  being copied. To replace a file on the device, copy it, then copy it back and compare; if it did not change, stop and
  find out why instead of forcing it. Any command that deletes on someone's device needs their yes first.
- Never commit or log a development `.p12` or its password.
- Ask before launching or preparing games on a device someone else is using: it kills whatever they have open.
- To copy a large folder (a game) into the app's `Documents` on a device, use `prep/devsync.py <device-id> <local-dir>
  <remote-dir-under-Documents>`: it compares sizes and copies only what is missing, with retries, so it can be rerun
  after an interruption. It reads the bundle ID from `MACSHACK_BUNDLE_ID` or `Signing.xcconfig`; options are in its
  docstring.
- `samples/MiniCocoa` is the smallest AppKit + Metal guest app (`samples/MiniCocoa/build.sh` builds `MiniCocoa.app`), for
  trying the prepare and launch path without a game.

## Mac-side checks

Commands run from the repository root. `/tmp/t` is just a scratch binary. Where a row says "header", the build line is
in that file's first lines.

### Installer and preparation

| Check | Command |
|---|---|
| Native on-device prep (unsigned, no game or key needed) | `python3 host/probe/test_native_prep.py` |
| Transactional installer (fake signer) | `python3 host/probe/test_installer.py` |
| ShackPrep's Mach-O edits and gap reports | `python3 prep/test_shackprep.py` |
| Case-insensitive guest paths (mounts a case-sensitive APFS image) | header of `host/probe/test_case_paths.m` |
| A whole game folder copied into Staging | `swiftc -parse-as-library host/StagedFolder.swift host/probe/test_staged_folder.swift -o /tmp/t && /tmp/t` (expect `staged folder ok`) |
| Launch arguments games need (known fixes, log rules) | `swiftc -parse-as-library host/AutoConfig.swift host/probe/test_auto_config.swift -o /tmp/t && /tmp/t` |
| Command line of native Swift games | `swiftc -parse-as-library host/GuestArguments.swift host/probe/test_guest_arguments.swift -o /tmp/t && /tmp/t` (expect `guest arguments ok`) |
| Developer ID trust for `SHACK_MAC_CODESIGN` (needs a Developer ID-signed Mach-O) | header of `host/probe/test_mac_code_trust.m` |
| libcurl stubs (iOS simulator) | header of `host/probe/test_curl_stub.c` (expect `curl stub ok`) |
| App icon (ICNS) parser | `swiftc -parse-as-library host/ICNS.swift host/probe/test_icns.swift -o /tmp/t && /tmp/t "<Game.app>/Contents/Resources/<icon>.icns"` |

Incoming apps go to `Documents/Staging`, installed data lives in `Documents/Games`, and signed guest code in
`Library/Guests`. Launch arguments a game needs belong in `host/AutoConfig.swift`. A game's own arguments live in
`Documents/Games/<Name>.args`, one per line; MacShack keeps a copy in `Library/GameConfigs/<bundle id>.args`, which
survives Delete and is put back at launch when the game's `.args` is missing or still the default. Every host install
invalidates prepared games (the install record pins the host executable's hash), so prepare each game again after
installing a new build (`--prepare "<Name>"` or **Prepare again**).

### Signing

| Check | Command |
|---|---|
| ZSign fixture (needs pkg-config and OpenSSL; no real key) | `python3 host/probe/test_signing.py --test-zsign` |
| Signing a built host app | `python3 host/probe/test_signing.py --host-app build/Build/Products/Release-iphoneos/MacShack.app --output /tmp/<new-unique-directory>` |
| On the device (uses the development `.p12` imported on first run) | launch with `--on-device-sign-probe` (or the in-app button), then read `Documents/Logs/on-device-signing.log` |

What the signing path relies on: iOS 27 loads a same-team, developer-signed dylib from outside the app bundle when its
**code-signing identifier** matches the installed profile's app bundle identifier; entitlements on the dylib are
optional (`codesign --force-library-entitlements` overrides the default omission). ZSign is patched to omit bare-library
entitlements, use 16 KB code-signing pages and sign SHA-256 only. Copy signed output to a **new inode before `dlopen`**,
or iOS kills dyld on a cached invalid page.

### Graphics and AppKit

| Check | Command |
|---|---|
| Textures and views (BC decoding) | `clang -fobjc-arc -DSHACK_BC_TEST shims/AppKit/ShackGLTexture.m shims/AppKit/ShackASTC.c host/probe/test_bc.m -framework Foundation -o /tmp/t && /tmp/t` |
| S3TC-to-ASTC transcoder against Arm's reference decoder | `host/probe/test_astc.c` (its header lists the astc-encoder build) |
| GLSL 1.x shaders on OpenGL ES 3 (iOS simulator; a folder of shaders) | header of `host/probe/test_glsl_legacy.m` |
| Virtual display geometry (`SHACK_DISPLAY_SIZE`) | `clang host/probe/test_display_profile.c -framework CoreGraphics -o /tmp/t && /tmp/t` |
| Layer autoresizing (iOS simulator; Chromium's layer tree) | header of `host/probe/test_layer_resize.m` (expect `layer resize ok`) |
| Main-nib parsing | header of `host/probe/test_nib.m` |
| Quit sequence (`terminate:`, `applicationShouldTerminate:`) | `clang -fobjc-arc shims/AppKit/ShackTerminate.m host/probe/test_terminate.m -framework Foundation -o /tmp/t && /tmp/t` (expect `terminate ok`) |
| MacShack's first screen (iOS simulator preview) | header of `host/probe/test_launcher.swift` |

### Input

| Check | Command |
|---|---|
| On-screen controller touch mapping (simulator) | header of `host/probe/test_touch_controls.swift` |
| On-screen controller pad (Mac; also `xcrun simctl spawn booted` for iOS) | `clang -fobjc-arc host/ShackTouchPad.m host/probe/test_touch_pad.m -framework GameController -framework Foundation -o /tmp/t && /tmp/t` |
| Virtual HID gamepad, both pad identities | `clang -fobjc-arc -DSHACK_HID_TEST shims/IOKit/ShackHID.m host/probe/test_shack_hid.m -framework Foundation -framework GameController -o /tmp/t && /tmp/t && SHACK_HID_PAD=xbox2016 /tmp/t` |
| Text input (`interpretKeyEvents:`) | `clang -fobjc-arc shims/AppKit/ShackTextInput.m host/probe/test_textinput.m -framework Foundation -o /tmp/t && /tmp/t` (expect `text input ok`) |
| Key events from Steam's on-screen keyboard (`CGEventPost`, iOS simulator) | header of `host/probe/test_cg_keys.m` (expect `cg keys ok`) |

### Steam

| Check | Command |
|---|---|
| Steam client setup: Valve's manifest, unpacking, compared with Valve's own install (downloads ~412 MB once) | header of `host/probe/test_steam_setup.swift` (expect `steam setup ok`) |
| In-process semaphores and shared memory for Steam (`shims/SteamClient/SteamIPC.c`) | `clang host/probe/test_steam_ipc.c shims/SteamClient/SteamIPC.c -o /tmp/t && /tmp/t` (expect `steam ipc ok`) |
| Steam's pthread keys beyond the process's 512 (`shims/SteamClient/SteamTSD.c`) | `clang host/probe/test_steam_tsd.c shims/SteamClient/SteamTSD.c -o /tmp/t && /tmp/t` (expect `steam tsd ok`) |
| An Intel game's Steam API under AArchX (Steam running) | header of `prep/aarchx/check_steam_api.c` (expect `steam api ok` with the same hash as Rosetta) |

New users get Steam from `host/SteamSetup.swift` (onboarding's last page, or **Set up Steam** on the first screen). A
Steam copied in by hand (no setup stamp) is never replaced unless someone taps **Update to latest Steam** or **Repair
Steam** in Settings, or launches with `--steam-setup`.

### Memory and Metal

| Check | Command |
|---|---|
| Memory tier (userspace swap) | `clang -Ihost host/ShackSwap.c host/probe/test_swap.c -o /tmp/t && /tmp/t` |

Hooks of `new*`/`copy*` selectors must return their +1 object untouched (`RETAINED` in `host/ShackMetal.m`), or a
game thread without an autorelease pool leaks everything.

### JIT

| Check | Command |
|---|---|
| JIT script (Node standard library only) | `node host/probe/test_jit_script.js` |
| Objective-C JIT compile check | `xcrun --sdk iphoneos clang -target arm64-apple-ios26.0 -fobjc-arc -fsyntax-only -Wall -Wextra host/ShackJIT.m` |
| Device probes | launch with `--jit-spike --jit-rewrite` or `--jit-spike --jit-alias`; add `--jit-debugger-alloc` to the rewrite probe to test debugger-allocated rather than ordinary mmap pages |

The built-in JIT: with `Documents/StikJIT/pairingFile.plist` on the device, launches and `--jit-spike` start the
`MacShackJIT` extension (`jithelper/`, StikJIT framework in `vendor/StikJIT`), which runs `host/probe/macshack-jit.js`
against MacShack; its log is `Documents/Logs/jit-helper.log`. Without a pairing file, run the same script in StikDebug
(Enable Script). Either way the device must stay unlocked and LocalDevVPN must be active.

What the JIT design rests on (tested on iPhone 17 Pro Max, iOS 27):

- Debugger-allocated RX memory plus a `vm_remap` RW alias survives repeated rewrites, including after the debugger
  detaches. This proves the allocator, not that Mono's same-address code manager can use it. Both same-address rewrite
  paths fail: ordinary RW mmap never acquires execute, and debugger-allocated RX loses maximum execute when changed to
  RW (a later `mprotect` to RX fails with `EACCES`). A blanket prepare-on-flush hook is therefore not an option, and
  Unity's Mono is rebuilt or trapped instead (below).
- `CS_DEBUGGED` is not proof of a live debugger connection or of executable memory. Read back VM protections and
  execute known code: `mprotect` can return success while execute permission is stripped.
- Stock StikDebug/StikJIT preparation writes `0x69` at each page start; it must not be applied to already-written code
  without preserving those bytes. MacShack's script reads and writes back the existing byte and checks each debugger
  response.

### Unity Mono

| Check | Command |
|---|---|
| Rebuild a runtime with the dual-mapped code manager | `prep/unity-mono/build.sh <commit>` (the revision comes from `strings libmonobdwgc-2.0.dylib \| grep explicit/`) |
| A game's stock runtime under `host/ShackTrapJIT.c` | [prep/unity-mono/trapjit/README.md](prep/unity-mono/trapjit/README.md) (expect `stress ok 40038350616`) |
| A rebuilt runtime on the Mac | system Mono 6.12 class libraries with the rebuilt `mono-boehm`, below |

```sh
MB=/Library/Frameworks/Mono.framework/Versions/6.12.0
MONO_PATH=$MB/lib/mono/4.5 MONO_CFG_DIR=$MB/etc SHACK_JIT_POOL_MB=64 <mono-src>/mono/mini/mono-boehm hello.exe
```

The build prefix's `libmono-native-compat.dylib` must point at the arm64 `mono/native/.libs/libmono-native.dylib` (the
6.12 framework's copy is x86_64 only). In the rebuilt runtime every store into code goes through
`mono_codeman_rw ()`, while pointers and relocations stay on the RX address. New code-write sites in Mono must use it
too, or they fault on the unwritable RX side (which is how the Mac test catches them). The pool comes from
`ShackJITPoolSetup` in the host via `SHACK_JIT_POOL`, or `SHACK_JIT_POOL_MB=<n>` for a mapping made on the Mac.
Revisions with no rebuild run on their own Mono: `host/ShackTrapJIT.c` replays its stores into the pool. Its decoder
handles STR/STUR/STP (general and SIMD registers), STXR/STXP/STLR, CAS and the LSE atomics; any other store logs
`[ShackTrapJIT] unhandled instruction`.

### AArchX (Intel games)

Build steps, the AArchX test suites and MacShack's `check_*` programs are in
[prep/aarchx/README.md](prep/aarchx/README.md). `prep/aarchx/smoke.sh [game...]` runs the Intel games in its own list
on the Mac for 30 s each, from the Mac's Steam library (`STEAM_LIBRARY` names a second library's `steamapps/common`). After editing `vendor/AArchX`, regenerate
`prep/aarchx/macshack.patch` with the command given there.

### Windows games (MacShack Play)

| Check | Command |
|---|---|
| Set up Windows games against the pinned downloads: verify, lay out, apply the ntdll patch, sign with the fake signer (downloads Madeira and Valve's files once) | header of `host/probe/test_windows_setup.swift` (expect `windows setup ok`) |
| Steam Play switched on and off on a scratch Steam folder | `clang -fobjc-arc -Ihost host/ShackSteamPlay.m host/probe/test_steam_play.m -framework Foundation -o /tmp/t && /tmp/t` (expect `steam play ok`) |
| MacShack and MacShack Play's Mach bridge | `clang -fobjc-arc -Ihost host/ShackPlayMach.m host/probe/test_play_mach.m -framework Foundation -o /tmp/t && /tmp/t` (expect `play mach ok`) |
| The engine's own folder and executable path in Play | header of `host/probe/test_engine_bundle.m` (expect `engine bundle ok`) |
| Madeira's engine has every symbol Play uses | `sh host/probe/test_engine_symbols.sh <Madeira-0.1.3.ipa>` (expect `engine symbols ok`) |
| Steam Play patch sites for another Steam build (needs capstone) | `python3 prep/steam-onehost/steamplay_sites.py <steamclient.dylib>`, then update `kSites` in `host/ShackSteamPlay.m` |
| The Windows kit zip (maintainers) | `windows-kit/release.sh` (see [windows-kit/README.md](windows-kit/README.md)), then pin the printed sha256 in `host/WindowsKit.swift` |
| On the device | launch with `--play-steam-wine` (expect `PASS` in `Documents/Logs/play-run.txt`) or `--play-run cube-x64.exe` |

## Rules for changes

- **Game-specific patches are a last resort** (none at the moment). They live in `prep/patch_<game>_*.py`, verify the
  original bytes before writing and are idempotent. Check: copy the Mac original to a scratch path, run the script
  twice, and expect `patched N site(s)`, then `already patched`.
- **Fix shims, not games.** A shim that fakes a system object must expose exactly the real object's properties and side
  effects (run loop sources, initial values): games probe them and trust the answer.
- **Keep changes to other projects' code as patches.** They live under `prep/` (`prep/aarchx/macshack.patch`,
  `prep/zsign-*.patch`, `prep/unity-mono/dualmap.patch`), applied to the pinned upstream source, never as commits
  inside `vendor/*`. Mark each AArchX change `MacShack:`.
- **`windows-kit/` is GPL-3.0 and stays separate.** Nothing in it is compiled into MacShack or MacShack Play; the
  device downloads its release zip. Changes to NotProton's code are patches there
  (`windows-kit/lsteamclient/macshack-unixlib.patch`). Changing `windows-kit/` means a new kit release (`KIT_VERSION`
  + 1) and its sha256 pinned in `host/WindowsKit.swift`. Valve's Windows files are never committed or put in the kit.
- Update [docs/compat-status.md](docs/compat-status.md) when a game's state changes, with the date.
- One commit per finding; the message says what broke and why the change fixes it.
- No game content in the repository, ever.

## Debugging a game

See [docs/compat-playbook.md](docs/compat-playbook.md): where the logs are, a symptom-to-cause triage table, launch
arguments, and the bring-up method for native and Intel games.
