#!/bin/bash
# Intel game smoke test under AArchX (ocerz) native mode, the only mode iOS can use.
# SECS (default 30) per game; logs in build/aarchx-smoke/. Pass game names to run a subset. STEAM_LIBRARY: a second
# Steam library's steamapps/common (default: the one in ~/Library/Application Support/Steam).
# DIAG=1: 4 s before the end, SIGINFO (ocerz dumps every guest thread) and `sample` the native stacks.
# Build first: see prep/aarchx/README.md.
cd "$(dirname "$0")/../../vendor/AArchX" || exit 1
A=$PWD; S="$HOME/Library/Application Support/Steam/steamapps/common"; L=${STEAM_LIBRARY:-$S}
LOG=$A/../../build/aarchx-smoke; mkdir -p "$LOG"
SECS=${SECS:-30}
run() {
  name=$1 exe=$2
  [ -n "$ONLY" ] && [[ " $ONLY " != *" $name "* ]] && return
  touch "$LOG/.start-$name"
  ( cd "$(dirname "$exe")" && OCERZ_FPS=1 exec perl -e 'alarm shift; exec @ARGV' "$SECS" "$A/ocerz" -native "$exe" >"$LOG/$name-native.log" 2>&1 ) &
  pid=$!
  if [ -n "$DIAG" ] && [ "$SECS" -gt 6 ]; then
    for ((i = 0; i < SECS - 4; i++)); do kill -0 $pid 2>/dev/null || break; sleep 1; done
    if kill -0 $pid 2>/dev/null; then
      kill -INFO $pid
      sample $pid 2 -file "$LOG/$name.sample.txt" >/dev/null 2>&1 && echo "  (native stacks: $LOG/$name.sample.txt)"
    fi
  fi
  wait $pid 2>/dev/null; rc=$?
  P="$HOME/Library/Logs/Unity/Player.log"
  logs=("$LOG/$name-native.log"); [ "$P" -nt "$LOG/.start-$name" ] && logs+=("$P")
  echo "== $name exit=$rc lines=$(wc -l <"$LOG/$name-native.log") fps=$(cat "${logs[@]}" | grep -o 'FPS\[[0-9]*\] [0-9.]*' | tail -1)"
  grep -v '^\s*$' "$LOG/$name-native.log" | tail -4 | cut -c1-240
  # Unity sends stdout/stderr, ocerz's errors included, to Player.log once it starts
  [ "$P" -nt "$LOG/.start-$name" ] && { echo "  -- Player.log:"; tail -3 "$P" | cut -c1-240; }
}
ONLY="$*"
run shovel     "$S/Shovel Knight/ShovelKnight.app/Contents/MacOS/ShovelKnight"
run cyber      "$S/Cyber Shadow/CyberShadow.app/Contents/MacOS/Chowdren"
run gravity    "$S/Gravity Circuit/GravityCircuit.app/Contents/MacOS/GravityCircuit"
run akane      "$S/Akane/Akane.app/Contents/MacOS/Akane"
run blasphemous "$S/Blasphemous/Blasphemous.app/Contents/MacOS/Blasphemous"
run hades      "$L/Hades/Hades.app/Contents/MacOS/Game.macOS"
