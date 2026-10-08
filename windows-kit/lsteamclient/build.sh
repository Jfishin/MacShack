#!/bin/bash
# lsteamclient for MacShack Play: Valve's Proton lsteamclient with NotProton's macOS files (NotProton's own
# lsteamclient/fetch.sh fetches Proton at its pinned commit and checks the tree's digest) and MacShack's change for
# Madeira (macshack-unixlib.patch), built for Madeira's Wine (ARM64EC) on iOS:
#   build/kit/arm64ec-windows/lsteamclient.dll   the PE half (winegcc against wine-tree.sh's tree, llvm-mingw)
#   build/kit/aarch64-unix/lsteamclient.so       the unix half: an iOS arm64 dylib MacShack Play loads itself and whose
#                                                call table it hands to the PE half (play/MadeiraEngine.m); ntdll's unix
#                                                exports (KeUserModeCallback, __wine_dbg_*, ...) resolve from Madeira's
#                                                engine at load.
# The patch and both built halves are under the Steamworks SDK license, as Proton and NotProton ship lsteamclient
# (notproton/LICENSE.lsteamclient); this script itself is MacShack's, GPL-3.0-or-later like the rest of windows-kit/
# (LICENSE).
#   windows-kit/lsteamclient/build.sh      both halves (incremental; FETCH=1 assembles the tree again, JOBS=<n> sets the
#                                          compile parallelism, default: every core)
# The first run needs the network (NotProton's fetch.sh downloads Proton from codeload.github.com) and python3.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
kit=$(cd "$here/.." && pwd)
. "$kit/pins.sh"
b=$kit/build
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
np=$b/notproton
wine=$b/wine
ec=$b/wine-arm64ec
src=$b/lsteamclient-src
tree=$src/tree
out=$b/kit
obj=$src/obj
for need in "$ec/tools/winegcc/winegcc" "$ec/dlls/user32/arm64ec-windows/libuser32.a" "$ec/include/config.h" \
            "$np/lsteamclient/fetch.sh"; do
  [ -e "$need" ] || { echo "==> missing $need: run fetch.sh and wine-tree.sh" >&2; exit 1; }
done
export PATH="$b/$LLVM_MINGW/bin:$PATH"
command -v arm64ec-w64-mingw32-clang >/dev/null || { echo "==> no llvm-mingw: run fetch.sh" >&2; exit 1; }

# fetch.sh reassembles the tree with fresh mtimes each time, which would rebuild every object: only when missing.
[ -f "$tree/Makefile.in" ] && [ -z "${FETCH:-}" ] || WORK=$src/proton TREE=$tree sh "$np/lsteamclient/fetch.sh"
# MacShack's changes for Madeira (Valve's license, like the files they change): each applied once.
for p in "$here"/*.patch; do
  patch -d "$tree" -p1 -R -s -f --dry-run < "$p" >/dev/null 2>&1 || patch -d "$tree" -p1 -s -f < "$p"
done
mkdir -p "$obj/pe" "$obj/unix" "$out/arm64ec-windows" "$out/aarch64-unix"

# Makefile.in's SOURCES: .c = PE half, .cpp = unix half (link order kept).
sources=$(sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\.c\(pp\)\{0,1\}\)[[:space:]]*\\\{0,1\}[[:space:]]*$/\1/p' "$tree/Makefile.in")
pe=$(echo "$sources" | grep '\.c$')
unix=$(echo "$sources" | grep '\.cpp$')
echo "==> $(echo "$pe" | wc -l | tr -d ' ') PE sources, $(echo "$unix" | wc -l | tr -d ' ') unix sources"

# No -g (the kit ships no debug info) and the prefix map: the zip is released, so no half may carry the builder's home path
# (__FILE__ strings, DWARF, the linker's debug-map stabs); checked below.
common="-I$tree -D__WINESRC__ -DSTEAM_API_EXPORTS -Dprivate=public -Dprotected=public -O2 -ffile-prefix-map=$b=build -Wno-pragma-pack -Wno-macro-redefined"
pe_cc="arm64ec-w64-mingw32-clang -D__STDC__ $common -I$ec/include -I$wine/include -I$wine/include/msvcrt -D_UCRT
  -D__WINE_PE_BUILD -target arm64ec-windows --no-default-config -fno-strict-aliasing -ffunction-sections
  -fasync-exceptions -ffp-exception-behavior=maytrap"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
unix_cc="xcrun -sdk iphoneos clang++ -arch arm64 -isysroot $sdk -miphoneos-version-min=17.0 -std=gnu++17 -fPIC $common
  -I$ec/include -I$wine/include -DWINE_UNIX_LIB -Wno-deprecated-declarations -Wno-format-extra-args"

# Each object rebuilt when its source is newer.
# ponytail: tracks only each source's mtime, not headers, flags or the pins; FETCH=1, or remove build/lsteamclient-src/obj
# after changing flags or pins.
compile() {   # kind file
  local kind=$1 file=$2 o
  o=$obj/$kind/${file%.*}.o
  [ -f "$o" ] && [ "$o" -nt "$tree/$file" ] && return 0
  if [ "$kind" = pe ]; then $pe_cc -c -o "$o.tmp" "$tree/$file" 2>"$o.err"; else $unix_cc -c -o "$o.tmp" "$tree/$file" 2>"$o.err"; fi \
    && mv "$o.tmp" "$o" || { echo "==> $kind $file failed:"; grep -m5 error "$o.err"; return 1; }
}
export -f compile; export obj tree pe_cc unix_cc
echo "$pe" | sed 's/^/pe /' | xargs -P "$JOBS" -L1 bash -c 'compile "$0" "$1"'
echo "$unix" | sed 's/^/unix /' | xargs -P "$JOBS" -L1 bash -c 'compile "$0" "$1"'

echo "==> linking the PE half"
# -timestamp:0 (winegcc links in lld-link mode here, which has no --no-insert-timestamp): no link time in the PE header, so
# every build has the same bytes (the kit's pinned sha256 holds).
"$ec/tools/winegcc/winegcc" -o "$out/arm64ec-windows/lsteamclient.dll" --wine-objdir "$ec" \
  --cc-cmd="arm64ec-w64-mingw32-clang -D__STDC__" -b arm64ec-windows -Wl,--wine-builtin -Wl,-timestamp:0 -shared "$tree/lsteamclient.spec" \
  $(for f in $pe; do echo "$obj/pe/${f%.c}.o"; done) \
  "$ec/dlls/user32/arm64ec-windows/libuser32.a" "$ec/dlls/ws2_32/arm64ec-windows/libws2_32.a" \
  "$ec/libs/winecrt0/arm64ec-windows/libwinecrt0.a" "$ec/libs/compiler-rt/arm64ec-windows/libcompiler-rt.a" \
  "$ec/dlls/ucrtbase/arm64ec-windows/libucrtbase.a" "$ec/dlls/kernel32/arm64ec-windows/libkernel32.a" \
  "$ec/dlls/ntdll/arm64ec-windows/libntdll.a" --no-default-config
# The Wine import libraries linked in above (winecrt0, ...) were built with -g and carry DWARF naming the builder's home
# (the linker ignores -Wl,--strip-debug through winegcc): llvm-strip drops it; only sizes change in the PE headers.
llvm-strip --strip-debug "$out/arm64ec-windows/lsteamclient.dll"

echo "==> linking the unix half"
xcrun -sdk iphoneos clang++ -arch arm64 -isysroot "$sdk" -miphoneos-version-min=17.0 -dynamiclib \
  -install_name @rpath/lsteamclient.so -o "$out/aarch64-unix/lsteamclient.so" \
  $(for f in $unix; do echo "$obj/unix/${f%.cpp}.o"; done) -Wl,-undefined,dynamic_lookup

# Sanity: a link that dropped objects is orders of magnitude smaller; the exports Wine's loader and the PE half need.
dll=$out/arm64ec-windows/lsteamclient.dll so=$out/aarch64-unix/lsteamclient.so
[ "$(stat -f %z "$dll")" -gt 1000000 ] && [ "$(stat -f %z "$so")" -gt 1000000 ] || { echo "==> a half is too small" >&2; exit 1; }
grep -q ' ___wine_unix_call_funcs$' <(nm -gU "$so") || { echo "==> the unix half exports no __wine_unix_call_funcs" >&2; exit 1; }
grep -q '^Wine builtin DLL' <(strings -a "$dll") || { echo "==> the PE half lacks Wine's builtin marker" >&2; exit 1; }
grep -q MONO_MACSHACK_UNIXLIB_LSTEAMCLIENT <(strings -a "$dll") || { echo "==> the PE half lacks MacShack's unixlib patch" >&2; exit 1; }
! grep -q -a "$HOME" "$dll" "$so" || { echo "==> a half contains $HOME (debug info or __FILE__)" >&2; exit 1; }
echo "lsteamclient ok: $dll ($(stat -f %z "$dll") bytes), $so ($(stat -f %z "$so") bytes, $(lipo -archs "$so"))"
