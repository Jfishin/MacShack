#!/bin/bash
# The Windows kit, from its public sources (pins.sh) to one zip for a release of this repository (windows-kit-<N>),
# which MacShack downloads on the device (host/WindowsKit.swift pins the zip's sha256):
#   build/macshack-windows-kit-<KIT_VERSION>.zip
# Runs every step, then adds the notices and SOURCE: windows-kit/'s git tree id and every pin, the kit's complete
# source. Commit first (SOURCE names the committed folder); DIRTY_OK=1 builds from uncommitted changes for a try, never a release.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"
b=$here/build
kit=$b/kit
dirty=$(git -C "$here" status --porcelain -- .)
[ -z "$dirty" ] || [ -n "${DIRTY_OK:-}" ] || { echo "==> windows-kit/ has uncommitted changes: commit first" >&2; exit 1; }
"$here/fetch.sh"
"$here/wine-tree.sh"
"$here/lsteamclient/build.sh"
"$here/ntdll/build.sh"
"$here/steam-exe.sh"
"$here/helpers/build.sh"
mkdir -p "$kit/notproton"
cp -f "$here/LICENSE" "$here/NOTICE" "$kit/"
cp -f "$here"/notproton/* "$kit/notproton/"
# The license texts of the Wine and LLVM libraries linked into lsteamclient.dll (Madeira's Wine, $b/wine) and steam.exe
# (the upstream Wine tree steam-exe.sh built from), and of the mingw-w64 runtime in the helpers (llvm-mingw):
# <name in the kit> <source file>.
npw=${NP_WINE:-/private/tmp/macshack-windows-kit/np-wine}/wine
mkdir -p "$kit/licenses"
while read -r name from; do
  [ -s "$from" ] || { echo "==> no $from for licenses/$name" >&2; exit 1; }
  cp -f "$from" "$kit/licenses/$name"
done <<EOF
madeira-wine-COPYING.LIB $b/wine/COPYING.LIB
madeira-wine-compiler-rt.txt $b/wine/libs/compiler-rt/LICENSE.TXT
wine-COPYING.LIB $npw/COPYING.LIB
wine-compiler-rt.txt $npw/libs/compiler-rt/LICENSE.TXT
wine-libc++.txt $npw/libs/c++/LICENSE.TXT
wine-libc++abi.txt $npw/libs/c++abi/LICENSE.TXT
wine-libunwind.txt $npw/libs/unwind/LICENSE.TXT
mingw-w64-runtime.txt $b/$LLVM_MINGW/x86_64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt
EOF
# Read before the heredoc: a failing command inside its $(...) would not stop the script, and SOURCE would ship blank.
kit_tree=$(git -C "$here" rev-parse HEAD:./)
np_tag=$(git -C "$npw" describe --tags)
np_commit=$(git -C "$npw" rev-parse HEAD)
np_url=$(git -C "$npw" remote get-url origin)
mingw_gcc=$(x86_64-w64-mingw32-gcc --version | head -1)
[ -n "$kit_tree" ] || { echo "==> no commit for windows-kit/ (commit first)" >&2; exit 1; }
cat > "$kit/SOURCE" <<EOF
MacShack Windows kit $KIT_VERSION
Built from https://github.com/Jfishin/MacShack, folder windows-kit/ with git tree $kit_tree (git rev-parse <commit>:windows-kit; the release windows-kit-$KIT_VERSION points at such a commit)${dirty:+, with uncommitted changes: not a release}, with:
  NotProton $NOTPROTON_TAG ($NOTPROTON_COMMIT), $NOTPROTON_URL
  Valve's Proton lsteamclient at the commit NotProton's lsteamclient/fetch.sh pins
  NotProton's steam-shim (steam.exe), built by its bridge/setup-wine-tree.sh with upstream Wine
  $np_tag ($np_commit, $np_url),
  the commit that script pins, and $mingw_gcc
  Wine $WINE_COMMIT ($WINE_URL):
    build tools, headers, import libraries, and winecrt0 + compiler-rt linked into lsteamclient.dll
  $LLVM_MINGW ($LLVM_MINGW_URL)
  Madeira v0.1.3's arm64ec-windows/ntdll.dll ($MADEIRA_IPA_URL): the detour's addresses
EOF
files="ntdll.patch.json arm64ec-windows/lsteamclient.dll aarch64-unix/lsteamclient.so steam/steam.exe steam/msi.dll
  steam/macshack-launch.exe steamapi-test.exe LICENSE NOTICE SOURCE notproton/NOTICE notproton/LICENSE.lsteamclient
  notproton/LICENSE.steam-shim licenses/madeira-wine-COPYING.LIB licenses/madeira-wine-compiler-rt.txt
  licenses/wine-COPYING.LIB licenses/wine-compiler-rt.txt licenses/wine-libc++.txt licenses/wine-libc++abi.txt
  licenses/wine-libunwind.txt licenses/mingw-w64-runtime.txt"
for f in $files; do [ -s "$kit/$f" ] || { echo "==> the kit lacks $f" >&2; exit 1; }; done
for f in steamclient.dll steamclient64.dll tier0_s64.dll vstdlib_s64.dll; do   # Valve's: downloaded on the device
  [ ! -e "$kit/steam/$f" ] || { echo "==> $f is Valve's and never in the kit" >&2; exit 1; }
done
for f in $files; do   # the zip is public: no builder's home path (debug info, __FILE__) in any released file
  ! grep -q -a "$HOME" "$kit/$f" || { echo "==> $f contains $HOME" >&2; exit 1; }
done
zip=$b/macshack-windows-kit-$KIT_VERSION.zip
# Fixed file times (zip records them) and links without a timestamp: the zip is the same on every run, so its pinned sha256
# stays valid after a rebuild. SOURCE names windows-kit/'s tree, not a commit: a change elsewhere, such as the pin of this
# zip's sha256 in host/WindowsKit.swift (even in the same commit), leaves the zip alone.
rm -f "$zip"
# shellcheck disable=SC2086
(cd "$kit" && TZ=UTC touch -t 202001010000 $files && TZ=UTC zip -X -q "$zip" $files)
shasum -a 256 "$zip"
