#!/bin/bash
# Runtime dumps for compat_audit.py: every class and protocol method on macOS (AppKit loaded) and on an iOS Simulator
# (UIKit loaded), plus the public class names in the macOS SDK headers. Rerun after an Xcode or iOS update.
set -e
cd "$(dirname "$0")"
clang -fobjc-arc objc_dump.m -framework Foundation -o dump_mac
xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=26.0 -fobjc-arc objc_dump.m -framework Foundation -o dump_sim
FW=/System/Library/Frameworks
COMMON="QuartzCore Metal MetalKit GameController AVFoundation AVFAudio CoreImage GameKit IOSurface CoreVideo SpriteKit WebKit StoreKit CoreHaptics UniformTypeIdentifiers CoreText"
A=(); for f in AppKit Carbon $COMMON; do A+=("$FW/$f.framework/$f"); done
./dump_mac "${A[@]}" > mac.tsv
I=(); for f in UIKit OpenGLES $COMMON; do I+=("$FW/$f.framework/$f"); done
U=${SIM_UDID:-$(xcrun simctl list devices available | grep -m1 -oE '[0-9A-F-]{36}')}
xcrun simctl boot "$U" 2>/dev/null || true
xcrun simctl bootstatus "$U" -b >/dev/null
xcrun simctl spawn "$U" "$PWD/dump_sim" "${I[@]}" > ios.tsv
xcrun simctl shutdown "$U"
SDK=$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks
grep -rhoE "^@interface +[A-Z][A-Za-z0-9_]+" "$SDK"/*.framework/Headers "$SDK"/*.framework/Frameworks/*.framework/Headers 2>/dev/null \
  | awk '{print $2}' | sort -u > mac_public_classes.txt
wc -l mac.tsv ios.tsv mac_public_classes.txt
