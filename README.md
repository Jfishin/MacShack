# MacShack

**Play the Mac and Windows games you own on an iPhone or iPad. No jailbreak.**

<p align="center">
  <img src="docs/images/hero.png" width="820"
       alt="Screenshot to add: a game running full screen on the iPhone in landscape">
</p>

MacShack is an iOS app that runs desktop games on Apple's mobile devices. Mac games built for Apple silicon run natively;
Intel Mac games and Windows games are translated as they run. Valve's own Steam client comes with it: Big Picture,
sign-in, downloads, cloud saves and controllers, the way they work on a Mac.

## What it does

- **Apple silicon Mac games run natively:** Unity, Unreal, Godot, GameMaker, SDL and more. MacShack adapts each game's
  code for iOS and signs it on the device; the game's files stay untouched.
- **Intel Mac games** are translated to ARM as they run, by [AArchX](https://github.com/mont127/AArchX).
- **Windows games** run in **MacShack Play**, a companion app, on Will Faust's Madeira (Wine) engine. Install them from
  Big Picture and press Play, as on a Steam Deck. *Early, but real games play.*
- **Steam, built in.** Valve's macOS Steam client runs inside MacShack in Big Picture mode, set up on the device from
  Valve's servers. Steam Play compatibility tools are enabled by [NotProton](https://github.com/NotProtonNot/NotProton).
- **Local Games:** any Mac game you copy in yourself. Place games in MacShack's `Staging` folder and prepare them on
  the device.
- **Controllers:** any Bluetooth controller, or MacShack's on-screen Xbox-style pad.
- **Per-game tuning:** frame-rate cap, render scale, resolution, memory swap and launch options. Hold the Dynamic Island
  during a game for MacShack's menu.

MacShack contains no games and no Valve software. You bring the games you own, and Steam is downloaded from Valve on
your device.

## Screenshots

<table>
  <tr>
    <td><img src="docs/images/launcher.png" alt="Screenshot to add: the launcher's Steam page"></td>
    <td><img src="docs/images/big-picture.png" alt="Screenshot to add: Steam Big Picture inside MacShack"></td>
    <td><img src="docs/images/touch-controls.png" alt="Screenshot to add: a game with the on-screen controller"></td>
  </tr>
  <tr>
    <td align="center">The launcher</td>
    <td align="center">Steam Big Picture</td>
    <td align="center">On-screen controller</td>
  </tr>
  <tr>
    <td><img src="docs/images/game-native.png" alt="Screenshot to add: an Apple silicon Mac game"></td>
    <td><img src="docs/images/game-intel.png" alt="Screenshot to add: an Intel Mac game"></td>
    <td><img src="docs/images/game-windows.png" alt="Screenshot to add: a Windows game in MacShack Play"></td>
  </tr>
  <tr>
    <td align="center">Mac game (Apple silicon)</td>
    <td align="center">Mac game (Intel)</td>
    <td align="center">Windows game</td>
  </tr>
</table>

## How it works

```
Mac game ──► prepare ─────────────► loader ──► the game ──► shims ──────────────► iOS
             adapt + sign on                   (Intel:      macOS frameworks
             the device                         AArchX)     rebuilt on iOS ones

Windows game ──► Steam Play ──► MacShack Play ──► Madeira (Wine + x86 translation) ──► iOS
```

- **Prepare and sign.** iOS runs only code signed for the app. MacShack rewrites a game's executables for iOS and signs
  them on the device with your own developer certificate, then loads them against the untouched game files.
- **Shims.** Mac games call macOS frameworks that iOS lacks. MacShack ships a stand-in for each one, built on the real
  iOS framework: AppKit on UIKit, IOKit's gamepad API on GameController, desktop OpenGL on OpenGL ES, Core Audio and
  more.
- **JIT.** Games that compile code while they run (Unity's Mono, Intel and Windows games) need executable memory, which
  iOS grants only through a debugger. MacShack's built-in helper (StikJIT) attaches at launch and prepares that memory.
  Unity Mono details: [prep/unity-mono/README.md](prep/unity-mono/README.md).
- **Intel games.** AArchX translates x86-64 code to ARM inside MacShack and routes the game's system calls to the same
  shims. Details: [prep/aarchx/README.md](prep/aarchx/README.md).
- **Steam.** iOS allows an app no child processes, so Valve's Steam client, its Chromium interface and the game it starts
  all run inside MacShack's one process. Details: [prep/steam-onehost/README.md](prep/steam-onehost/README.md).
- **MacShack Play.** Windows games run in a second app that takes the foreground with Game Mode (more memory, CPU and GPU
  priority), while Steam keeps running in MacShack behind it. Steam Play starts the game there, and the game talks to
  that same Steam.

## Building

MacShack is source only for now: you build it on a Mac and install it with your own Apple developer account. The
build steps will be written here once they are final. Meanwhile, you can get everything below ready.

**On your Mac**

- Xcode 26.4 or newer (Mac App Store), signed in to your Apple Account (Xcode > Settings > Accounts).
- [Homebrew](https://brew.sh), then XcodeGen and the GitHub CLI: `brew install xcodegen gh`.
- An Apple developer account. A free one works, with limits: apps stop opening after 7 days until you install them
  again, at most 3 apps can be installed through it at once, and it can register 10 new App IDs a week. MacShack uses
  two App IDs (the app and its JIT extension); MacShack Play, for Windows games, is a second app.

**On your iPhone or iPad**

- iOS 26 or later (tested on iOS 27, iPhone 17 Pro Max and iPad Pro M5).
- Developer Mode on: Settings > Privacy & Security > Developer Mode. It appears after the device has been connected to
  Xcode once.
- LocalDevVPN from the App Store. Games that need JIT (Unity Mono, Intel and Windows games) start only while it is on.
- Free space: about 420 MB for Steam, plus your games.

**For MacShack's first run** (it asks for these, sent over with AirDrop):

- Your development certificate as a `.p12` file with a password: Keychain Access > My Certificates > the Apple
  Development certificate > Export. Xcode creates that certificate the first time it signs an app for your account,
  so this comes after your first build.
- Your device's pairing file in the RPPairing (Remote Pairing) format, made on your Mac with
  [idevice_pair](https://github.com/jkcoxson/idevice_pair) and saved as `pairingFile.plist`. An older pairing file
  stops JIT with "missing public_key".
- Your Steam account.

A Bluetooth controller is nice to have; MacShack also has an on-screen pad.

## Getting games onto the device

MacShack runs games you own. There are two ways to get them in:

- **Steam Big Picture** (recommended). Press **Steam Big Picture** on MacShack's first screen, then install and play as
  on a Mac. Windows games install to the "MacShack Play" library and run in MacShack Play.
- **Local Games.** Copy a Mac game (its `.app`, or the whole game folder) into MacShack's `Staging` folder with the Files
  app or Finder, then tap **Prepare** in Local Games.

## Contributing and docs

- [CONTRIBUTING.md](CONTRIBUTING.md): checks that run on a Mac, and the rules for changes.
- [docs/compat-playbook.md](docs/compat-playbook.md): how to bring up a game that doesn't run yet.
- [docs/compat-status.md](docs/compat-status.md): every game tried, and what's still open.

## Credits and licenses

MacShack stands on these projects:

| Component | Where | License |
|---|---|---|
| [AArchX](https://github.com/mont127/AArchX) (x86-64 translator) | `vendor/AArchX`, `prep/aarchx/macshack.patch` | LGPL-2.1, built as its own library (`libOcerz`) so it stays replaceable |
| [ZSign](https://github.com/zhlynn/zsign) (on-device signing) | `vendor/zsign`, `prep/zsign-*.patch` | MIT |
| [StikJIT](https://github.com/StikDebug/StikJIT) (JIT helper), with [idevice](https://github.com/jkcoxson/idevice) inside | `vendor/StikJIT` | MPL-2.0; idevice MIT |
| [fishhook](https://github.com/facebook/fishhook) | `host/vendor/fishhook.c` | BSD-3-Clause |
| Unity's Mono fork | `prep/unity-mono` (patch only) | MIT, some third-party parts BSD |
| GNU libstdc++ (for x86 games) | fetched by `prep/aarchx/guest_libstdcxx.sh` and `guest32_libstdcxx.sh` | GPLv3 with the GCC Runtime Library Exception |
| [Madeira](https://github.com/willfaust/Madeira) by Will Faust: Wine, FEX-Emu and DXMT for iOS (MacShack Play's engine) | not in this repository | GPL-3.0 |
| [NotProton](https://github.com/NotProtonNot/NotProton) (Steam Play on macOS): MacShack Play follows its approach and runs its launcher files | not in this repository | GPL-3.0 |

Thanks also to [StikDebug](https://github.com/StikDebug/StikDebug) and
[idevice_pair](https://github.com/jkcoxson/idevice_pair), which make JIT possible on a stock iPhone.

Valve's Steam client, Madeira, NotProton and the games themselves are not part of this repository.

## License

MacShack's own code is released under the [MIT License](LICENSE). Third-party components keep their own licenses
(table above).
