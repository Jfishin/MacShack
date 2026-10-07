#!/bin/bash
# Guest GNU libstdc++ for AArchX native mode: old Unity players and games built with it (Aragami, Blasphemous,
# Enter the Gungeon) import its old-ABI symbols (COW std::string, _Rb_tree_*, iostreams), which the guest libc++
# does not have.  Source: MacPorts' x86_64 build of GCC 15's runtime (GPLv3 with the GCC Runtime Library Exception).
set -euo pipefail
cd "$(dirname "$0")/../../vendor/AArchX"
G=runtime/guest/usr/lib
F=libgcc15-15.2.0_0+stdlib_flag.darwin_25.x86_64.tbz2
T=$(mktemp -d)
curl -sfL -o "$T/$F" "https://packages.macports.org/libgcc15/$F"
echo "3ef91a4a5d4ab71bc7dd6a623d5398fb956e92a68a4cff8e6ca807128e713593  $T/$F" | shasum -a 256 -c -
tar -xjf "$T/$F" -C "$T" ./opt/local/lib/libgcc/libstdc++.6.dylib
clang -arch x86_64 -dynamiclib -install_name /usr/lib/libgnu-compat.dylib -compatibility_version 10.0.0 -O2 \
  ../../prep/aarchx/gnu-compat.c -liconv $G/libunwind.1.dylib -o $G/libgnu-compat.dylib
install -m 644 "$T/opt/local/lib/libgcc/libstdc++.6.dylib" $G/libstdc++.6.dylib
install_name_tool -id /usr/lib/libstdc++.6.dylib -change /opt/local/lib/libiconv.2.dylib /usr/lib/libgnu-compat.dylib \
  $G/libstdc++.6.dylib 2>/dev/null
codesign -f -s - $G/libstdc++.6.dylib
rm -rf "$T"
