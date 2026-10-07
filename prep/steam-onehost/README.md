# One-process Steam (Mac prototype)

iOS gives MacShack one process: no `fork`, no `posix_spawn`. Valve's macOS Steam client is 9 processes (steam_osx,
Steam Helper = CEF browser, its GPU/renderer/utility children, crashpad, ipcserver), and every game it starts is another.
This prototype runs steam_osx, the Steam Helper browser (CEF `--single-process`) and a game Steam launches in **one**
Mac process, to learn what the iOS host must do.

```
prep/steam-onehost/build.sh                                  # installs beside steam_osx (additive files only)
prep/steam-onehost/build.sh game ".../steamapps/common/Mina the Hollower/Mina the Hollower.app"   # prepare a game
ONEHOST_HELPER_ARG=--js-flags=--jitless prep/steam-onehost/run.sh -gamepadui   # quit the normal Steam first
prep/steam-onehost/build.sh uninstall
```
`ONEHOST_NO_SPAWN=1` refuses every real fork/exec/posix_spawn/popen/app launch, as iOS would.

Log: `~/Library/Application Support/Steam/logs/onehost.log` (and stderr). `-cef-enable-debugging` puts DevTools on
`127.0.0.1:8080`. Stop a run with SIGKILL: SIGTERM is ignored and `steam_osx -shutdown` does not find it.

## How it works (onehost.m)
- **Images**: steam_osx and Steam Helper are converted to dylibs with shackprep's `exec_to_dylib` and run from their
  `LC_MAIN`. The helper gets private copies of tier0, vstdlib and SDL3 (`lib*_h`/`libSDLh`), as a separate process
  would: tier0 holds one "main thread" and command line, SDL3 one event queue.
- **Spawning**: steam_osx starts the helper with tier0's `CreateSimpleProcess(argv, flags, envp, cwd)` (fork + execv;
  the handle is the pid, polled with `kill`/`waitid`/`waitpid`). That call is interposed: the helper runs in-process
  under fake pid 1000001, which those three answer. Everything else still spawns for real (Mac only).
- **One main thread, three programs**: AppKit, SDL and CEF all need the real main thread, and steam_osx makes NSWindows
  at startup, so none can move to another thread. All run on it as fibers, round robin (an asm stack switch; objc's
  autorelease pool TLS slot 43 is swapped too). Switch points: `nextEventMatchingMask` (a guest's event loop does one
  non-blocking pass, then yields) and main-thread `nanosleep`/`usleep` (steam_osx waits for the helper's shared memory in
  a sleep loop; while a game runs, sleeps are 1 ms slices of turns). Never inside a run loop callout. This is a Mac
  artifact: on iOS the AppKit guests see is MacShack's shim, which already gives each guest its own app thread.
- **Identity, by calling image**: a guest's images get its own `_NSGetExecutablePath`, `proc_pidpath`,
  `_NSGetArgc/Argv`; a game's also its own `getenv` (the environment Steam gave it), `getpid` (its fake pid),
  `CFBundleGetMainBundle`/`+[NSBundle mainBundle]`, `exit`/`_exit` (end the guest, not the process) and `dlopen` of
  `steamclient.dylib` (its private copy). CEF gets `--framework-dir-path` and `--main-bundle-path`.
- **Games**: Steam starts a Mac game with `-[NSWorkspace launchApplicationAtURL:options:configuration:error:]`
  (launch options in the arguments; `SteamAppId`, `SteamOverlayGameId`, `SteamTenfoot`, controller lists,
  `STEAM_DYLD_INSERT_LIBRARIES` in the environment), reads the pid of the returned `NSRunningApplication` and watches it
  with `kevent(EVFILT_PROC)`. For a prepared game (`build.sh game`: converted executable, its dylibs, a private
  steamclient/tier0/vstdlib/libaudio set in `onehost-guests/<Game>.app/`) the hook returns a stand-in
  `NSRunningApplication` with fake pid 1000002 and starts the game on a fiber; its kevent watch becomes an EVFILT_USER
  event triggered when the game ends. Unprepared games launch normally.
- **What iOS takes away**: steam_osx re-execs itself unless `STEAM_CLIENT_CONFIG_FILE` and `STEAM_APP_BUNDLE_PATH` are set
  (the host sets them); games find Steam through ipcserver's Mach service `com.valvesoftware.steam.ipctool` (emulated:
  `bootstrap_check_in`/`bootstrap_look_up` share one port, ipcserver runs on a thread); Steam vouches for local TCP
  connections with `popen("lsof ...")` (answered in-process when one of this process's sockets uses the port).
- **Shown (2026-10-03)**: Mina the Hollower launched from Big Picture runs in-process, renders its intro, its Steam API
  registers with the in-process Steam ("Game process updated", Steam UI lists it Running). Whole process ~2 GB.
- **Not yet**: Steam's Stop (kill/terminate are ignored; NSApp and its delegate are shared, so `[NSApp terminate:]`
  would end Steam too); a second game per session (images cannot be unloaded); the game's `chdir` is the whole
  process's; Steam's "waiting for game window" times out after ~24 s (it matches windows by pid); no overlay
  (`STEAM_DYLD_INSERT_LIBRARIES` is not loaded); the main thread is saturated by turn-taking (AppKit window updates on
  every pass).

## Measured (M-series Mac, Big Picture page-switch bench, 2026-10-03)
| | fps | page switch | CPU | memory |
|---|---|---|---|---|
| normal Steam, 9 processes, JIT | 58 | 88 ms | 0.8 cores | ~1.4 GB |
| one process, JIT | 58 | 92 ms | 0.75 cores | ~960 MB |
| one process, `--jitless` (the iPhone case) | 55 | 184 ms | 0.75 cores | ~900 MB |
| (earlier) software rendering, jitless | 5.5 | 250 ms | 1.6 cores | 2.3 GB |
