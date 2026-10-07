#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=MiniCocoa.app; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
clang -target arm64-apple-macos13.0 -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore main.m -o "$APP/Contents/MacOS/MiniCocoa"
cp Info.plist "$APP/Contents/"
codesign -f -s - "$APP"
echo "built $APP"
