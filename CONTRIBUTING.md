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

## Mac-side checks

Commands run from the repository root. `/tmp/t` is just a scratch binary. Every other `host/probe/test_*` file gives its
own build line in its header.

### Installer and preparation

| Check | Command |
|---|---|
| Native on-device prep (unsigned, no game or key needed) | `python3 host/probe/test_native_prep.py` |
| Transactional installer (fake signer) | `python3 host/probe/test_installer.py` |
| Case-insensitive guest paths (mounts a case-sensitive APFS image) | see the header of `host/probe/test_case_paths.m` |
| Launch arguments games need (known fixes, log rules) | `swiftc -parse-as-library host/AutoConfig.swift host/probe/test_auto_config.swift -o /tmp/t && /tmp/t` |
| App icon (ICNS) parser | `swiftc -parse-as-library host/ICNS.swift host/probe/test_icns.swift -o /tmp/t && /tmp/t "<Game.app>/Contents/Resources/<icon>.icns"` |
| Steam client setup: Valve's manifest, unpacking, compared with Valve's own install (downloads ~412 MB once) | see the header of `host/probe/test_steam_setup.swift` (expect `steam setup ok`) |

Incoming apps go to `Documents/Staging`, installed data lives in `Documents/Games`, and signed guest code in
`Library/Guests`. Launch arguments a game needs belong in `host/AutoConfig.swift`; the device keeps each game's custom
`.args` in `Library/GameConfigs/<bundle id>.args`. Every host install invalidates prepared games (the install record
pins the host executable's hash), so prepare each game again after installing a new build.

### Signing

| Check | Command |
|---|---|
| ZSign fixture (needs pkg-config and OpenSSL; no real key) | `python3 host/probe/test_signing.py --test-zsign` |
| Signing a built host app | `python3 host/probe/test_signing.py --host-app build/Build/Products/Debug-iphoneos/MacShack.app --output /tmp/<new-unique-directory>` |
| On the device | launch with `--on-device-sign-probe` (or the in-app button), then read `Documents/Logs/on-device-signing.log` |

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
| Main-nib parsing | `host/probe/test_nib.m` (build line in its header) |

### Input

| Check | Command |
|---|---|
| On-screen controller touch mapping (simulator) | see the header of `host/probe/test_touch_controls.swift` |
| On-screen controller pad (Mac; also `xcrun simctl spawn booted` for iOS) | `clang -fobjc-arc host/ShackTouchPad.m host/probe/test_touch_pad.m -framework GameController -framework Foundation -o /tmp/t && /tmp/t` |
| Virtual HID gamepad, both pad identities | `clang -fobjc-arc -DSHACK_HID_TEST shims/IOKit/ShackHID.m host/probe/test_shack_hid.m -framework Foundation -framework GameController -o /tmp/t && /tmp/t && SHACK_HID_PAD=xbox2016 /tmp/t` |

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

What the JIT design rests on (iPhone 17 Pro Max, iOS 27):

- Debugger-allocated RX memory plus a `vm_remap` RW alias survives repeated rewrites, including after the debugger
  detaches. Both same-address rewrite paths fail: ordinary RW mmap never acquires execute, and debugger-allocated RX
  loses maximum execute when changed to RW (a later `mprotect` to RX fails with `EACCES`). A blanket prepare-on-flush
  hook is therefore not an option.
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
Revisions with no rebuild run on their own Mono: `host/ShackTrapJIT.c` replays its stores into the pool (an unhandled
store logs `[ShackTrapJIT] unhandled instruction`).

### AArchX (Intel games)

Build steps, the AArchX test suites and MacShack's `check_*` programs are in
[prep/aarchx/README.md](prep/aarchx/README.md). `prep/aarchx/smoke.sh <game>` runs an Intel game on the Mac for 30 s.
After editing `vendor/AArchX`, regenerate `prep/aarchx/macshack.patch` with the command given there.

## Rules for changes

- **Game-specific patches are a last resort.** They live in `prep/patch_<game>_*.py`, verify the original bytes before
  writing and are idempotent. Check: copy the Mac original to a scratch path, run the script twice, and expect
  `patched N site(s)`, then `already patched`.
- **Fix shims, not games.** A shim that fakes a system object must expose exactly the real object's properties and side
  effects (run loop sources, initial values): games probe them and trust the answer.
- **Mark vendored edits.** Local edits inside code we vendor (`vendor/*`) are marked `MacShack:` and
  listed in that directory's README or patch.
- Update [docs/compat-status.md](docs/compat-status.md) when a game's state changes, with the date.
- One commit per finding; the message says what broke and why the change fixes it.
- No game content in the repository, ever.

## Debugging a game

See [docs/compat-playbook.md](docs/compat-playbook.md): where the logs are, a symptom-to-cause triage table, launch
arguments, and the bring-up method for native and Intel games.
