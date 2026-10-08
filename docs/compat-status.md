# Compatibility status

What has been tried on the test device (iPhone 17 Pro Max, iOS 27.0, A19 Pro), as of **2026-10-07**. Dates are when the
state was last observed; a later commit may have changed it, so re-test before trusting a row. "Native" = arm64 macOS
build prepared and signed on the device. "Intel" = x86_64 build translated by AArchX. Method and triage: [compat-playbook.md](compat-playbook.md).

Rows dated before 2026-10-07 were tested with a Steam stand-in MacShack no longer has; results that depend on Steam may
differ now. Retest from Big Picture.

## Native arm64

| Game | Engine | State | Notes |
|---|---|---|---|
| Big Hops | Unity 6, Mono | Playable (9-26), 60 fps cap, touch, audio | Black boot until the phone is rotated |
| Lies of P | Unreal 4.27 | Playable with gamepad and sound (9-25) | Throttles thermally after about 5 min; texture pool is 70% of reported VRAM |
| Hollow Knight: Silksong | Unity, Mono | Main menu, touch, audio, gamepad (9-25) | Gameplay not tested |
| Slots & Daggers | Unity, stock Mono | Playable (9-27), about 42 fps | On the game's own Mono via ShackTrapJIT |
| Okko The Exiled | Unity 6000.0, stock Mono, FMOD Studio | Plays with audio and controller (10-02) | FMOD with 2 x 256 DSP buffers was silent until HAL units got the Mac's 512-frame IO buffer and the session rate as `nsrt`. Quitting faults after the game ends (IOKit shim notification into UnityPlayer) |
| Death Must Die | Unity 2021.3, stock Mono | Playable (9-27), about 55 fps | Needed a `Gestalt` (Carbon) shim |
| Rubinite | Unity | Works (9-27) | |
| Valheim | Unity, Mono | Starts (9-27) | Retest from Big Picture (PlayFab rejected the old stand-in's tickets) |
| Dave the Diver | Unity 6, IL2CPP | Reaches its menu (9-28) | |
| Stray | Unreal 4.27 | Boots to the game at about 60 fps with audio (9-27) | Gameplay not tested. Needs project-folder detection and case-insensitive dlopen |
| Mina the Hollower | SDL2 | Played (9-26) | Falls back to local saves without Steam |
| Factorio 2.0 | SDL2, Metal | Main menu at 60 fps with audio (9-27) | |
| Cosmic Call | Godot 3.5, GLES3 via `ShackGL`, GodotSteam | Playable (9-26) | Needs two data files: an `override.cfg` beside the executable with `[rendering]` `quality/reflections/high_quality_ggx=false`, `texture_array_reflections=false`, `irradiance_max_size=64` (the desktop radiance filter locked up the GPU), and the game's own `savefile.ini` and `config.ini` (from `Contents/Resources/UI/main/`) copied into its Godot user-data folder |
| Parking Garage Rally Circuit | Godot 4.5, Metal | Playable at 60 fps after a first-run shader compile (9-26) | Needs `--rendering-method` `forward_plus` in `.args` (upstream godot#123060) |
| Coromon | Solar2D / CoronaCards, native GL | Plays to the title (9-28) | Touch input is rough; audio and saves unchecked |
| Crimson Desert | Pearl Abyss BlackSpace, Metal 4, Swift/AppKit | Menus at 60 fps, 960x540 (`SHACK_MAC_CODESIGN`, virtual display); gameplay stuck loading (9-29) | AutoConfig supplies its arguments. Applying settings can hit a GPU InvalidInput error; the loading cause is unknown |
| Cyberpunk 2077 (Epic Mac build 2.3.1) | REDengine 4, Metal, MetalFX | Plays its built-in benchmark with an Xbox pad (10-07), ~30 fps GPU-bound, ~5 GB free | Copy the game's whole Mac folder into Staging (the 10 non-English voice packs can stay behind) and Prepare. Prepare quarters its ~139 GB of pool reservations (the phone has ~55 GB of address space); libcurl is stubbed (offline: news, rewards); Epic sign-in fails and the game carries on. Steam/GOG builds untested |
| Hades II | The Forge, SDL2 | Paused | Renders at about 50 fps, then a memory kill after about 20 s (BC7 textures, heaps) |
| Sly Cooper (Mac port) | raylib / GLFW | Dropped | Needs a JIT its own libs use; 37 ticks/s without it |

## Intel x86_64 (AArchX)

| Game | Engine | State | Notes |
|---|---|---|---|
| Cyber Shadow | Chowdren, OpenGL | Title screen at 60 fps | First game up on the phone |
| Hades | The Forge, Metal | Locked 60 fps (9-27) | Needed inlined SSE integer ops; judders under "thermal serious" |
| Celeste | MonoKickstart, FNA3D GL | Plays from Big Picture on Valve's Steam API (10-07), ~56 fps; audio fixed (9-27) | A 256 MB pool filled in minutes; MonoKickstart games now get 1 GB. Real fix (shared block prologues or a pool flush) not done |
| Akane | Unity 2018.2, Mono | "PRESS ANY KEY" at 60 fps (9-27) | `-force-metal`. Its intro quit was Valve's `RestartAppIfNecessary`; retest pending |
| Subnautica | Unity 2019.4, GL only | Plays (9-28) | BC/DXT re-encoded to ASTC; underwater is black (suspect non-sRGB drawable or RGBA32F targets); needs a GPU trace |
| Aragami | Unity 2017.2, GL only | Title screen (9-28) | CGL layer, GLSL 410 to ES |
| Cuphead | Unity 2017.4 | Plays with a controller (9-28) | Rewired needs the 2016 Xbox identity. Open: inputs sometimes stick until re-pressed (queue overflow suspected). No DLC |
| Blasphemous | Unity 2017.4, non-PIE | Title screen at 60 fps (9-28) | Black screen after the title (seen without a Steam API); retest from Big Picture |
| BioShock Remastered (Feral) | Feral engine, Metal, Intel/AArchX | Main menu (9-29), about 8 fps, reached with a Steam stub no longer in MacShack; retest | Registry (`Preferences Data`): `UseMetal=1`, `MetalUseGLToSwap=0` under IndirectX's Direct3D Config (the default Metal-to-GL swap was black), `FullScreen=0` under the game's Setup. Fixes: HFS paths, options window, JIT fusion, ImageIO, FMOD CD probe, subviews, OpenAL thunks, posted events, window geometry. Launcher notes: [compat-playbook.md](compat-playbook.md), Feral section |
| Shovel Knight | custom engine, GL | Boots (window, GL, FMOD Ex audio), then a malloc heap-corruption trap | Unresolved |
| Gravity Circuit | LÖVE / LuaJIT | Alignment fault (SIGBUS) after 15 log lines on the Mac (9-27) | Not tried on the phone |
| Enter the Gungeon | Unity, GNU libstdc++ | Not run since the libstdc++ guest existed | |

## i386 (32-bit): experimental

AArchX's m32 runs i386-only Mac games ([prep/aarchx/README.md](../prep/aarchx/README.md)). Batman: Arkham Asylum
(Feral) launches on the iPhone and stops early, at its PhysX setup (10-03); no i386 game is confirmed playable on a
device.

## Open across games

Unity black boot until rotation; Steam Input outside the Steam client; audio interruption restart after a call or
Siri; native-resolution selection needs the game's own menu; touch mapping for mouse-first games; sticky inputs in
Rewired games (Cuphead).
