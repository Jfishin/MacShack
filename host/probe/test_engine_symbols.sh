#!/bin/sh
# Mac check: Madeira's engine as MacShack downloads it (host/WindowsKit.swift's pin) has every symbol MacShack Play uses
# (play/MadeiraEngine.m): the entry points it finds with dlsym must be exported, and the local symbols its JIT-pool fix
# reads from the symbol table must be in the table.
#   sh host/probe/test_engine_symbols.sh ~/Library/Caches/MacShackWindowsSetupTest/Madeira-0.1.3.ipa
# Expect `engine symbols ok`.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$1" Payload/Madeira.app/Madeira.debug.dylib -d "$tmp"
dylib="$tmp/Payload/Madeira.app/Madeira.debug.dylib"
nm -gU "$dylib" > "$tmp/exported"
nm "$dylib" > "$tmp/syms"
missing=0
for s in wineserver_start wine_process_start madeira_display_set_layer madeira_get_present_count jit_install_trap_handler \
         ws_log_quiet wine_process_is_running madeira_set_vsync_locked winios_post_touch_down winios_post_touch_move \
         winios_post_touch_up winios_gamepad_set_state master_socket_timeout; do
  grep -q " _$s\$" "$tmp/exported" || { echo "MISSING $s"; missing=1; }
done
for s in unix_call_funcs unixcall_ios_push_jit_aliases ios_jit_mappings ios_jit_mapping_count ios_jit_current_peb ios_pool_lock \
         syscalls NtUnmapViewOfSection NtUnmapViewOfSectionEx; do
  grep -q " _$s\$" "$tmp/syms" || { echo "MISSING $s"; missing=1; }
done
[ "$missing" = 0 ] && echo "engine symbols ok"
