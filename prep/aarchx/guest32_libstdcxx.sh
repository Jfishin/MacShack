#!/bin/bash
# Guest i386 GNU libstdc++ and libgcc_s for m32 (i386 Mach-O games): Batman Arkham Asylum imports the old-ABI
# std::string, iostreams and _Rb_tree_* from /usr/lib/libstdc++.6.dylib, which macOS no longer ships.  Source:
# MacPorts' i386 build of GCC 15.2's runtime for darwin_10, the same GCC as the x86_64 guest libstdc++
# (guest_libstdcxx.sh; GPLv3 with the GCC Runtime Library Exception).  It runs as guest code; m32 finds /usr/lib names under runtime/guest32 first.
set -euo pipefail
cd "$(dirname "$0")/../../vendor/AArchX"
G=runtime/guest32/usr/lib
F=libgcc15-15.2.0_0+stdlib_flag.darwin_10.i386.tbz2
SHA=7ed674a36aacf8fcf742e2f63eac85c4fa9a04fbbdda784ab44fac1cee06ad16
T=$(mktemp -d)
curl -sfL -o "$T/$F" "https://packages.macports.org/libgcc15/$F"
if [ "$SHA" = PENDING ]; then shasum -a 256 "$T/$F"; else echo "$SHA  $T/$F" | shasum -a 256 -c -; fi
tar -xjf "$T/$F" -C "$T"
mkdir -p $G
for l in libstdc++.6.dylib libgcc_s.1.dylib libgcc_s.1.1.dylib libgcc_ehs.1.1.dylib; do
  src=$(find "$T/opt/local/lib" -name "$l" -type f | head -1)
  if lipo "$src" -info | grep -q "Non-fat"; then cp "$src" "$G/$l"; else lipo "$src" -thin i386 -output "$G/$l"; fi
  install_name_tool -id "/usr/lib/$l" "$G/$l" 2>/dev/null
done
# their own references to each other point at the MacPorts prefix: make them the /usr/lib names m32 resolves
for l in libstdc++.6.dylib libgcc_s.1.dylib libgcc_s.1.1.dylib libgcc_ehs.1.1.dylib; do
  for dep in $(otool -L "$G/$l" | awk 'NR>1 {print $1}' | grep '^/opt/local'); do
    install_name_tool -change "$dep" "/usr/lib/$(basename "$dep")" "$G/$l" 2>/dev/null
  done
done
otool -L $G/*.dylib
rm -rf "$T"
