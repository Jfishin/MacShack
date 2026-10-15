#!/bin/bash
# prep/metalgldrv/build.sh <iphoneos|iphonesimulator> <build dir>: libmetalgldrv.dylib from vendor/metalgldrv with
# macshack.patch applied, into <build dir>. Xcode runs it before MacShack and MacShack Play build (project.yml) and
# embeds the dylib. Needs cmake and ninja (brew install cmake ninja); without them, or without the submodule, it builds
# nothing and games' GL stays on ShackGL (ShackGLDrv.m falls back).
set -e
here=$(cd "$(dirname "$0")" && pwd)
M="$here/../../vendor/metalgldrv"
sdk=${1:?iphoneos or iphonesimulator}
B=${2:?build dir}
if [ ! -f "$M/CMakeLists.txt" ]; then
    echo "note: vendor/metalgldrv is not checked out (git submodule update --init vendor/metalgldrv): no metalgldrv"
    exit 0
fi
git -C "$M" apply --reverse --check "$here/macshack.patch" 2>/dev/null || git -C "$M" apply "$here/macshack.patch"
P="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin"
if ! PATH="$P" command -v cmake >/dev/null || ! PATH="$P" command -v ninja >/dev/null; then
    echo "warning: metalgldrv needs cmake and ninja (brew install cmake ninja): not built"
    exit 0
fi
# Xcode's build settings in the environment (SDKROOT, deployment targets, ...) are not CMake's: a clean environment.
run() { env -i HOME="$HOME" PATH="$P" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} "$@"; }
[ -f "$B/build.ninja" ] || run cmake -G Ninja -S "$M" -B "$B" -DCMAKE_TOOLCHAIN_FILE="$M/cmake/ios.cmake" \
    -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DMGL_BUILD_TESTS=OFF
run ninja -C "$B" metalgldrv
