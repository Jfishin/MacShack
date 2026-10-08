# windows-kit (GPL-3.0; see NOTICE)

Builds `build/macshack-windows-kit-<KIT_VERSION>.zip`, the Windows-side pieces MacShack Play needs for Steam
(lsteamclient, NotProton's ntdll detour as data, steam.exe, MacShack's helpers). Only the maintainer runs this; people
who build MacShack never need it: their device downloads the released zip.

Needs: Xcode (iOS SDK), Homebrew `mingw-w64 bison flex lld llvm`, Python 3 with `capstone` (`pip3 install capstone`),
the GitHub CLI for releasing. Everything else is fetched at the pins in `pins.sh`.

    windows-kit/release.sh          everything, then the zip and its sha256 (commit first: SOURCE names the committed folder)

The steps, each runnable alone: `fetch.sh`, `wine-tree.sh`, `lsteamclient/build.sh`, `ntdll/build.sh`,
`steam-exe.sh`, `helpers/build.sh`. Outputs collect in `build/kit/`.
