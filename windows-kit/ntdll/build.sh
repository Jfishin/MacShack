#!/bin/sh
# NotProton's ntdll steamclient detour for Madeira's ARM64EC ntdll.dll (NotProton's ntdll-patch/build64.sh, one site):
# Valve's steamclient64.dll then has every export pointed at lsteamclient's, the way Proton's ntdll does it, and its
# DllMain is skipped. Delivered as data, build/kit/ntdll.patch.json (make_patch.py), which MacShack applies on the
# device (host/WindowsKit.swift) as NotProton patches its copy of CrossOver on the Mac: no Madeira file is re-hosted.
# NotProton's detour.c and link64.ld (build/notproton, v1.0.3) are used unmodified; its toolchain (the system clang
# for a bare aarch64 target, Homebrew ld.lld and llvm-objcopy).
#   windows-kit/ntdll/build.sh      for build/madeira-ntdll.dll (fetch.sh: Madeira v0.1.3's)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
b="$(cd "$here/.." && pwd)/build"
NOTPROTON="$b/notproton"
export NOTPROTON
np="$NOTPROTON/ntdll-patch"
ntdll="$b/madeira-ntdll.dll"
work="$b/ntdll"
out="$b/kit/ntdll.patch.json"
for need in "$np/detour.c" "$np/link64.ld" "$np/resolve.py" "$ntdll"; do
  [ -f "$need" ] || { echo "==> missing $need: run fetch.sh" >&2; exit 1; }
done
mkdir -p "$work" "$b/kit"

python3 "$here/resolve_madeira.py" "$ntdll"   # the report, and the self-test once the values are pinned
eval "$(python3 "$here/resolve_madeira.py" --sh "$ntdll")"

CC=/usr/bin/clang   # NotProton builds with the shell's clang; pinned so a PATH with llvm-mingw first gives the same bytes
TARGET=aarch64-unknown-none-elf
LD=/opt/homebrew/bin/ld.lld
OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
"$CC" -target "$TARGET" -c -Os -ffreestanding -fno-stack-protector \
  -fno-asynchronous-unwind-tables -mgeneral-regs-only -ffixed-x18 "$np/detour.c" -o "$work/detour64_c.o"
# shim64.o: the name NotProton's link64.ld puts first in the cave.
"$CC" -target "$TARGET" -c -x assembler-with-cpp "$here/shim64-madeira.S" -o "$work/shim64.o" "-DLOAD_PATH=$NP_LOAD_PATH"
(cd "$work" && "$LD" -T "$np/link64.ld" -e shim_entry64 shim64.o detour64_c.o -o detour64_linked.elf \
  "--defsym=CAVE_VA=$NP_PAYLOAD_VA" \
  "--defsym=BM_RESUME_1=$NP_RESUME_VA" \
  "--defsym=LDR_GETDLLHANDLE=$NP_LDR_GET_DLL_HANDLE" \
  "--defsym=LDR_LOADDLL=$NP_LDR_LOAD_DLL" \
  "--defsym=NT_PROTECT=$NP_NT_PROTECT_VIRTUAL_MEMORY")
"$OBJCOPY" -O binary -j .cave "$work/detour64_linked.elf" "$work/detour64-madeira.bin"
size=$(wc -c < "$work/detour64-madeira.bin")
[ "$size" -le "$NP_CAVE_ROOM" ] || { echo "==> payload ($size bytes) does not fit the mapped cave ($NP_CAVE_ROOM)" >&2; exit 1; }
python3 "$here/resolve_madeira.py" --apply "$ntdll" "$work/ntdll.dll" "$work/detour64-madeira.bin"
python3 "$here/make_patch.py" "$ntdll" "$work/ntdll.dll" arm64ec-windows/ntdll.dll > "$out"
echo "ntdll ok: $out, payload $size bytes"
