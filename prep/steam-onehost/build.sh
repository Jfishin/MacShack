#!/bin/bash
# Builds the one-process Steam prototype and installs it beside steam_osx (additive files only; Steam's own files are
# never changed).
#   prep/steam-onehost/build.sh                     build + install
#   prep/steam-onehost/build.sh game <Game.app>     prepare a Steam game to run in-process (onehost-guests/<Game.app>/)
#   prep/steam-onehost/build.sh uninstall           remove everything installed or prepared
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
S="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents"
M="$S/MacOS"; H="$S/Frameworks/Steam Helper.app/Contents/MacOS"
guests="$HOME/Library/Application Support/Steam/onehost-guests"
installed=("$M/shacksteam" "$M/libonehost.dylib" "$M/steam_osx.onehost.dylib" "$M/Steam Helper.onehost.dylib"
  "$M/libtier0_h.dylib" "$M/libvstdlib_h.dylib" "$M/libSDLh.dylib" "$M/ipcserver.onehost.dylib")
if [ "${1:-}" = uninstall ]; then rm -rf "${installed[@]}" "$H/Steam Helper.onehost.dylib" "$guests"; echo removed; exit 0; fi

convert() {  # executable, output dylib, install name (at most 7 characters)
  python3 - "$1" "$2" "$3" "$repo/prep" <<'EOF'
import os, shutil, sys
src, dst, name, prep = sys.argv[1:]
sys.path.insert(0, prep); import shackprep
if os.path.exists(dst): os.remove(dst)   # a new inode: never rewrite an image a running Steam has mapped
shutil.copyfile(src, dst); shackprep.thin_arm64(dst); shackprep.exec_to_dylib(dst)
# shackprep names every converted image "guest"; two of them in one process need names of their own.
data = bytearray(open(dst, "rb").read())
i = data.index(b"guest\0", 0, 32 + int.from_bytes(data[20:24], "little"))
data[i:i + 8] = name.encode().ljust(8, b"\0")
open(dst, "wb").write(data)
EOF
  codesign -f -s - "$2"
}

# Private copies of Valve libraries for one guest, as its own process would load them: a shared tier0 has one "main
# thread" and one command line, a shared SDL3 one event queue, a shared steamclient is Steam's own end of its IPC.
# Args: directory, pairs old:new (library names without .dylib), then the files whose links to rewrite. Same-length
# names keep every load command its size; a copy whose name is longer keeps its old install id.
private_copies() {
  local dir=$1 pairs=$2; shift 2
  local renames=() p f
  for p in $pairs; do
    renames+=(-change "@loader_path/${p%:*}.dylib" "@loader_path/${p#*:}.dylib")
    rm -f "$dir/${p#*:}.dylib"; cp "$M/${p%:*}.dylib" "$dir/${p#*:}.dylib"
  done
  for f in "$@"; do
    local id=()
    for p in $pairs; do
      local old=${p%:*} new=${p#*:}
      if [ "$f" = "$new.dylib" ] && [ ${#old} -eq ${#new} ]; then id=(-id "@loader_path/$f"); fi
    done
    install_name_tool ${id[@]+"${id[@]}"} "${renames[@]}" "$dir/$f" 2>&1 | grep -v 'invalidate the code signature' || true
    codesign -f -s - "$dir/$f"
  done
}

if [ "${1:-}" = game ]; then
  app=${2%/}; exe="$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)"
  g="$guests/$(basename "$app")"; mkdir -p "$g"
  convert "$exe" "$g/$(basename "$exe").dylib" game
  for f in "$app/Contents/MacOS/"*.dylib; do [ -e "$f" ] && { rm -f "$g/$(basename "$f")"; cp "$f" "$g/"; }; done   # @loader_path
  private_copies "$g" "libtier0_s:libtier0_g libvstdlib_s:libvstdlib_g libaudio:libaudig steamclient:steamclient_g" \
    libtier0_g.dylib libvstdlib_g.dylib libaudig.dylib steamclient_g.dylib
  ln -sf "$M/crashhandler.dylib" "$g/crashhandler.dylib"   # tier0's crash handler stays shared
  echo "prepared: $g"; exit 0
fi

convert "$M/steam_osx" "$M/steam_osx.onehost.dylib" osx
convert "$M/ipcserver" "$M/ipcserver.onehost.dylib" ipcsrv
rm -f "$H/Steam Helper.onehost.dylib"   # older layout
convert "$H/Steam Helper" "$M/Steam Helper.onehost.dylib" helper
private_copies "$M" "libtier0_s:libtier0_h libvstdlib_s:libvstdlib_h libSDL3:libSDLh" \
  "Steam Helper.onehost.dylib" libtier0_h.dylib libvstdlib_h.dylib libSDLh.dylib
clang -fobjc-arc -dynamiclib -arch arm64 -framework Foundation -framework AppKit "$here/onehost.m" "$M/libtier0_s.dylib" \
  -install_name @executable_path/libonehost.dylib -o "$M/libonehost.dylib"
clang -arch arm64 "$here/main.c" "$M/libonehost.dylib" -o "$M/shacksteam"
echo "installed:"; printf '  %s\n' "${installed[@]}"
