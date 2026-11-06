#!/bin/sh
# Mac check: Madeira's engine as MacShack downloads it (host/WindowsKit.swift's pin; since 0.2.0 the app's executable,
# made a library on the device) exports every entry point MacShack Play finds with dlsym (play/MadeiraEngine.m).
#   sh host/probe/test_engine_symbols.sh ~/Library/Caches/MacShackWindowsSetupTest/Madeira-0.2.0.ipa
# Expect `engine symbols ok`.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$1" Payload/Madeira.app/Madeira -d "$tmp"
nm -gU "$tmp/Payload/Madeira.app/Madeira" > "$tmp/exported"
missing=0
for s in wineserver_start wine_process_start madeira_display_set_layer madeira_get_present_count jit_install_trap_handler \
         ws_log_quiet wine_process_is_running madeira_set_vsync_locked winios_post_touch_down winios_post_touch_move \
         winios_post_touch_up winios_gamepad_set_state master_socket_timeout; do
  grep -q " _$s\$" "$tmp/exported" || { echo "MISSING $s"; missing=1; }
done
[ "$missing" = 0 ] && echo "engine symbols ok"
