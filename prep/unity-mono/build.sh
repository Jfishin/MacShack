#!/bin/sh
# Rebuild Unity's Mono runtime (the exact revision a game ships, see README.md) with the MacShack
# dual-mapping patch, on a Mac with Xcode + brew autoconf/automake/libtool. Output: build/libmonobdwgc-2.0.dylib
# (macOS platform; prep/embed turns it into the iOS guest copy). ~10 min on an M-series Mac.
set -e
REV=${1:?usage: build.sh <unity-mono-commit> [srcdir]}
SRC=${2:-$HOME/src/unity-mono}
HERE=$(cd "$(dirname "$0")" && pwd)
if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC" && git -C "$SRC" remote add origin https://github.com/Unity-Technologies/mono.git
fi
git -C "$SRC" fetch -q --depth 1 --filter=blob:none origin "$REV" && git -C "$SRC" checkout -q FETCH_HEAD
git -C "$SRC" submodule update --init --depth 1 external/bdwgc
git -C "$SRC" apply --check "$HERE/dualmap.patch" && git -C "$SRC" apply "$HERE/dualmap.patch"
cd "$SRC"
SDK=$(xcrun --sdk macosx --show-sdk-path)
# Unity's build.pl flags for the macOS arm64 runtime (mcs/class libs not built). clang 21 defaults to C23 and
# turns several warnings into errors that this 2025 code base trips; gnu11 + downgrades restore the old behavior.
CCX="clang -arch arm64 -std=gnu11 -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
export CC="clang -arch arm64" CXX="clang++ -arch arm64" LIBTOOLIZE=$(command -v glibtoolize)
export CFLAGS="-mmacosx-version-min=11.0 -isysroot $SDK -g -Os" CPPFLAGS="-mmacosx-version-min=11.0 -isysroot $SDK"
export CXXFLAGS="$CFLAGS -stdlib=libc++" LDFLAGS="-stdlib=libc++"
[ -f mono/mini/Makefile ] || ./autogen.sh --disable-mcs-build --with-glib=embedded --disable-nls --with-mcs-docs=no \
  --prefix="$SRC-prefix" --enable-no-threads-discovery=yes --enable-ignore-dynamic-loading=yes \
  --enable-dont-register-main-static-data=yes --enable-thread-local-alloc=no --enable-unity-define=yes \
  --with-monotouch=no --host=aarch64-apple-darwinmacos12.2.0 --with-libgdiplus=libgdiplus.dylib \
  --enable-minimal=com,shared_perfcounters --disable-parallel-mark --enable-verify-defines --disable-btls
make -j"$(sysctl -n hw.ncpu)" -C external/bdwgc
make -j"$(sysctl -n hw.ncpu)" -C mono CC="$CCX" CCAS="$CCX"
mkdir -p "$HERE/build"
cp mono/mini/.libs/libmonoboehm-2.0.1.dylib "$HERE/build/libmonobdwgc-2.0.dylib"
strip -x "$HERE/build/libmonobdwgc-2.0.dylib"
install_name_tool -id "@executable_path/../Frameworks/MonoEmbedRuntime/osx/libmonobdwgc-2.0.dylib" "$HERE/build/libmonobdwgc-2.0.dylib"
echo "built $HERE/build/libmonobdwgc-2.0.dylib"
