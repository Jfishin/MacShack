#!/bin/bash
# m32_phone_smoke.sh <device> <aarchx tree> <test...>: AArchX's 32-bit test programs (<tree>/tests/m32/bin) on the
# phone, each wrapped as a tiny Local Games app ("M32 <test>") and run in MacShack Play: MacShack is launched with
# --prepare, then with --play-mac. Prints PASS/FAIL per test; logs in build/m32-phone/. Nothing on the phone is deleted.
# M32_BUNDLE is MacShack's bundle id (Signing.local.xcconfig's MACSHACK_BUNDLE_ID). The phone must be unlocked, with
# JIT available (the pairing file and LocalDevVPN), as for any Intel game.
# m32_phone_smoke.sh --compare <expected> <log> <status>: the comparison alone (Mac check of this script).
set -u

# Every line of <expected> but its last appears in <log> in order; the last, "exit N", matches <status>.
compare() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
want = open(sys.argv[1], errors="replace").read().splitlines()
log = open(sys.argv[2], errors="replace").read().splitlines()
status = sys.argv[3]
i = 0
for line in want[:-1]:
    while i < len(log) and log[i] != line:
        i += 1
    if i == len(log):
        print("missing line: " + line)
        sys.exit(1)
    i += 1
if want and want[-1] != "exit " + status:
    print("%s, ended with %s" % (want[-1], status))
    sys.exit(1)
PY
}

if [ "${1:-}" = --compare ]; then
    out=$(compare "$2" "$3" "$4") && echo PASS || echo "FAIL: $out"
    exit 0
fi

D=$1 T=$(cd "$2" && pwd); shift 2
B=${M32_BUNDLE:?set M32_BUNDLE to MacShack\'s bundle id}
OUT=$(cd "$(dirname "$0")/../.." && pwd)/build/m32-phone
mkdir -p "$OUT"
dc() { xcrun devicectl "$@" >>"$OUT/devicectl.log" 2>&1; }
container=(--device "$D" --domain-type appDataContainer --domain-identifier "$B")
fetch() { rm -f "$2"; dc device copy from "${container[@]}" --source "$1" --destination "$2"; }
launch() { dc device process launch --device "$D" --terminate-existing "$B" -- "$@"; }

for t in "$@"; do
    name="M32 $t" app="$OUT/M32 $t.app"
    [ -f "$T/tests/m32/bin/$t" ] || { echo "FAIL $t: no $T/tests/m32/bin/$t"; continue; }
    rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
    cp "$T/tests/m32/bin/$t" "$app/Contents/MacOS/"
    for lib in libm32t.dylib libm32dl.dylib; do [ -f "$T/tests/m32/bin/$lib" ] && cp "$T/tests/m32/bin/$lib" "$app/Contents/MacOS/"; done
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$t</string>
<key>CFBundleIdentifier</key><string>com.macshack.m32.$t</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
    dc device copy to "${container[@]}" --source "$app" --destination "Documents/Staging/$name.app" ||
        { echo "FAIL $t: copy to the phone"; continue; }
    launch --prepare "$name"
    prepared=
    for _ in $(seq 30); do   # ponytail: polls the Games folder every 2 s for 60 s; MacShack has no "prepared" signal
        sleep 2
        xcrun devicectl device info files "${container[@]}" --subdirectory "Documents/Games" 2>/dev/null | grep -q "$name.app" &&
            { prepared=1; break; }
    done
    [ -n "$prepared" ] || { echo "FAIL $t: not installed after 60 s (MacShack's Logs say why)"; continue; }
    fetch Documents/Logs/play-mac-runs.txt "$OUT/runs.txt"
    before=$(grep -c "$name ended (" "$OUT/runs.txt" 2>/dev/null)
    launch --play-mac "$name"
    ended=
    for _ in $(seq 60); do   # 3 s apart, 3 minutes: Play's JIT set-up takes ~10 s
        sleep 3
        fetch Documents/Logs/play-mac-runs.txt "$OUT/runs.txt"
        [ "$(grep -c "$name ended (" "$OUT/runs.txt" 2>/dev/null)" -gt "${before:-0}" ] && { ended=1; break; }
    done
    fetch "Documents/Logs/$t.log" "$OUT/$t.log"
    fetch Documents/Logs/play-mac.txt "$OUT/$t.play-mac.txt"
    [ -n "$ended" ] || { echo "FAIL $t: no end within 3 minutes ($OUT/$t.play-mac.txt)"; continue; }
    status=$(grep "$name ended (" "$OUT/runs.txt" | tail -1 | sed 's/.*ended (\(-*[0-9]*\)).*/\1/')
    if out=$(compare "$T/tests/m32/$t.expected" "$OUT/$t.log" "$status"); then echo "PASS $t"; else echo "FAIL $t: $out"; fi
done
