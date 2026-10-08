#!/bin/bash
# Madeira's Wine (willfaust/wine at the pinned commit) configured for ARM64EC with llvm-mingw, as Madeira's own
# arm64ec tree was (--enable-win64 --without-x --without-freetype --without-fontconfig --enable-archs=arm64ec), and
# only what lsteamclient builds against: Wine's tools (winegcc, winebuild), its generated headers, config.h for the
# unix half, and the seven import libraries the PE half links.
#   build/wine-arm64ec
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"
b=$here/build
src=$b/wine
tree=$b/wine-arm64ec
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
export PATH="$b/$LLVM_MINGW/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
command -v arm64ec-w64-mingw32-clang >/dev/null || { echo "==> no llvm-mingw: run fetch.sh" >&2; exit 1; }
[ "$(git -C "$src" rev-parse HEAD)" = "$WINE_COMMIT" ] || { echo "==> no Wine at $WINE_COMMIT: run fetch.sh" >&2; exit 1; }
if [ ! -f "$tree/Makefile" ]; then
  mkdir -p "$tree"
  (cd "$tree" && "$src/configure" --enable-win64 --without-x --without-freetype --without-fontconfig --enable-archs=arm64ec)
fi
libs="dlls/user32/arm64ec-windows/libuser32.a dlls/ws2_32/arm64ec-windows/libws2_32.a
  libs/winecrt0/arm64ec-windows/libwinecrt0.a libs/compiler-rt/arm64ec-windows/libcompiler-rt.a
  dlls/ucrtbase/arm64ec-windows/libucrtbase.a dlls/kernel32/arm64ec-windows/libkernel32.a
  dlls/ntdll/arm64ec-windows/libntdll.a"
# shellcheck disable=SC2086
make -C "$tree" -j"$JOBS" __tooldeps__ include/all $libs
for f in tools/winegcc/winegcc tools/winebuild/winebuild include/config.h $libs; do
  [ -e "$tree/$f" ] || { echo "==> $tree/$f was not built" >&2; exit 1; }
done
echo "wine tree ok"
