#!/bin/bash
set -euo pipefail
OUT="$SRCROOT/host/probe/out"; mkdir -p "$OUT"
MACSDK=$(xcrun --sdk macosx --show-sdk-path)

# 1. Metal library compiled for macOS. Skipped while up to date: the Metal toolchain is an on-demand asset that is not
#    always mounted when a build asks for it ("missing Metal Toolchain"), and this library rarely changes.
if [ ! "$OUT/mac.metallib" -nt "$SRCROOT/host/probe/mac.metal" ]; then
  xcrun -sdk macosx metal -c "$SRCROOT/host/probe/mac.metal" -o "$OUT/mac.air"
  xcrun -sdk macosx metallib "$OUT/mac.air" -o "$OUT/mac.metallib"
fi

# 2. Foundation dylib built with the macOS SDK, platform patched to iOS, signed.
clang -isysroot "$MACSDK" -target arm64-apple-macos13.0 -dynamiclib -fobjc-arc -framework Foundation \
  -install_name @rpath/machello.dylib "$SRCROOT/host/probe/machello.m" -o "$OUT/machello.dylib"
vtool -set-build-version ios 16.0 26.4 -replace -output "$OUT/machello.dylib" "$OUT/machello.dylib"
# Foundation pulls in other macOS system frameworks transitively (e.g. CoreFoundation); every
# /System/Library/Frameworks/<X>.framework/Versions/<L>/... path must lose its Versions/<L>/
# component, since that path shape doesn't exist on iOS.
otool -L "$OUT/machello.dylib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
  case "$dep" in
    /System/Library/Frameworks/*/Versions/*)
      fixed=$(echo "$dep" | sed -E 's#(/System/Library/Frameworks/[^/]+\.framework)/Versions/[^/]+/#\1/#')
      install_name_tool -change "$dep" "$fixed" "$OUT/machello.dylib"
      ;;
  esac
done
codesign -f -s "$EXPANDED_CODE_SIGN_IDENTITY" "$OUT/machello.dylib"

# 3. Plain macOS executable for the loader self-test (patched by shackprep).
clang -isysroot "$MACSDK" -target arm64-apple-macos13.0 "$SRCROOT/host/probe/hello.c" -o "$OUT/hello"

# 3b. Convert the hello executable to an iOS dylib with shackprep (same code path as real games).
python3 - "$OUT/hello" <<'PY'
import sys; sys.path.insert(0, __import__("os").environ["SRCROOT"] + "/prep")
import shackprep; p = sys.argv[1]
shackprep.set_ios_platform(p); shackprep.exec_to_dylib(p); shackprep.rewrite_links(p, {})
PY
codesign -f -s "$EXPANDED_CODE_SIGN_IDENTITY" "$OUT/hello"

xcrun --sdk iphoneos clang -target arm64-apple-ios26.0 -dynamiclib \
  -install_name @rpath/signing-fixture.dylib "$SRCROOT/host/probe/signing_fixture.c" -o "$OUT/signing-fixture.dylib"
codesign -f -s - "$OUT/signing-fixture.dylib"

# Copy into the app bundle's Resources.
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$OUT/mac.metallib" "$OUT/machello.dylib" "$OUT/hello" "$OUT/signing-fixture.dylib" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
