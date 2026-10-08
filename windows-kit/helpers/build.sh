#!/bin/bash
# MacShack's three small Windows programs, x86_64 as games are (llvm-mingw):
#   build/kit/steam/msi.dll              msi.c: the one msi function NotProton's steam.exe imports (Madeira has no msi)
#   build/kit/steam/macshack-launch.exe  launch.c: MacShack Play's starter (steam.exe with the game's command line)
#   build/kit/steamapi-test.exe          steamapi-test.c: the Steam API check behind --play-steam-wine
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
kit=$(cd "$here/.." && pwd)
. "$kit/pins.sh"
out=$kit/build/kit
export PATH="$kit/build/$LLVM_MINGW/bin:$PATH"
command -v x86_64-w64-mingw32-clang >/dev/null || { echo "==> no llvm-mingw: run fetch.sh" >&2; exit 1; }
mkdir -p "$out/steam"
# -Wl,--no-insert-timestamp: no link time in the PE headers, so every build has the same bytes (the kit's pinned sha256 holds).
x86_64-w64-mingw32-clang -O2 -Wl,--no-insert-timestamp -shared -nostdlib -Wl,-e,DllMainCRTStartup -o "$out/steam/msi.dll" "$here/msi.c"
x86_64-w64-mingw32-clang -O2 -Wl,--no-insert-timestamp -o "$out/steam/macshack-launch.exe" "$here/launch.c" -lntdll -luser32
# GUI subsystem, as games are: started by steam.exe (a GUI program), a console program would get a conhost.exe, which
# Madeira cannot run as a child yet.
x86_64-w64-mingw32-clang -O2 -Wl,--no-insert-timestamp -mwindows -o "$out/steamapi-test.exe" "$here/steamapi-test.c"
for f in steam/msi.dll steam/macshack-launch.exe steamapi-test.exe; do
  file "$out/$f" | grep -q 'PE32+ .*x86-64' || { echo "==> $f is not an x86_64 PE" >&2; exit 1; }
done
echo "helpers ok"
