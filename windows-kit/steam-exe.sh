#!/bin/bash
# NotProton's steam.exe (its steam-shim: a port of Proton 9's steam_helper, BSD-3-Clause) built as NotProton builds it:
# its own bridge/setup-wine-tree.sh (upstream Wine at the tag it pins, configured for i386 and x86_64 with Homebrew's
# mingw-w64) and steam-shim/build.sh, from build/notproton at the pinned release. Then compared with the steam.exe in
# NotProton's own release (NotProton.zip), timestamp and checksum fields aside (its bridge/pe-info.py).
#   build/kit/steam/steam.exe
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"
b=$here/build
np=$b/notproton
# NotProton's layout: the Wine source and its build tree side by side. Outside the home folder: NotProton's configure gets
# absolute source paths, which land in steam.exe's assert strings (jsoncpp, libc++abi, libunwind), and the kit zip is
# public. A fixed path also keeps rebuilds alike on any Mac. /private/tmp empties on restart: the next run clones and
# builds again (~2 min).
npw=${NP_WINE:-/private/tmp/macshack-windows-kit/np-wine}
export WINE_SRC=$npw/wine WINE_BUILD=$npw/wine-build-dual
mkdir -p "$npw" "$b/kit/steam"
# Wine's configure passes CROSSLDFLAGS to every PE link: no link time in steam.exe's header, so every build has the same
# bytes (the kit's pinned sha256 holds). A tree configured without it (an older run of this script) is configured again.
export CROSSLDFLAGS=-Wl,--no-insert-timestamp
[ ! -f "$WINE_BUILD/Makefile" ] || grep -q -e --no-insert-timestamp "$WINE_BUILD/Makefile" || rm -rf "$WINE_BUILD"
"$np/bridge/setup-wine-tree.sh"
BRIDGE_DIR=$b/np-bridge "$np/steam-shim/build.sh"
cp -f "$WINE_BUILD/programs/steam.exe/x86_64-windows/steam.exe" "$b/kit/steam/steam.exe"
unzip -p "$b/NotProton.zip" '*payload/bridge/steam.exe' > "$b/notproton-release-steam.exe"
ours=$(python3 "$np/bridge/pe-info.py" "$b/kit/steam/steam.exe")
theirs=$(python3 "$np/bridge/pe-info.py" "$b/notproton-release-steam.exe")
# The kit zip needs no debug info; ours only, after the comparison above.
"$b/$LLVM_MINGW/bin/llvm-strip" --strip-debug "$b/kit/steam/steam.exe"
! grep -q -a "$HOME" "$b/kit/steam/steam.exe" || { echo "==> steam.exe contains $HOME" >&2; exit 1; }
if [ "$ours" = "$theirs" ]; then echo "steam.exe ok: the same as NotProton's release ($ours)"
else echo "steam.exe ok: built ($ours); NotProton's release differs ($theirs): another mingw-w64 version"; fi
