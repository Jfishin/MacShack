#!/bin/bash
# The Windows kit's inputs, each from its public source at the pin in pins.sh, into windows-kit/build/ (git-ignored):
#   build/notproton            NotProton at its release tag (lsteamclient/, ntdll-patch/, steam-shim/, bridge/)
#   build/wine                 Madeira's Wine (willfaust/wine) at the commit Madeira's release pins
#   build/<llvm-mingw>         the llvm-mingw toolchain Madeira builds with
#   build/madeira-ntdll.dll    the ARM64EC ntdll.dll of Madeira's release: the detour is made for this file
#   build/build/madeira_cfg.h  Madeira's build/madeira_cfg.h, which its Wine includes from ../build/ (Madeira's tree has wine/ beside build/)
#   build/NotProton.zip        NotProton's own release, to compare our steam.exe with (steam-exe.sh)
# Each is checked against its pin; one already there and matching is kept.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/pins.sh"
b=$here/build
mkdir -p "$b"
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
fetch() {   # url file sha256
  [ "$(sha "$2")" = "$3" ] && return 0
  curl -fL --retry 2 -o "$2.part" "$1" && mv "$2.part" "$2" || { echo "==> download of $1 failed" >&2; exit 1; }
  [ "$(sha "$2")" = "$3" ] || { echo "==> $2 does not match its pin" >&2; exit 1; }
}

np=$b/notproton
if [ ! -d "$np/.git" ]; then   # cloned beside, renamed only when whole
  rm -rf "$np.part"
  git clone -q --depth 1 --branch "$NOTPROTON_TAG" "$NOTPROTON_URL" "$np.part"
  mv "$np.part" "$np"
fi
[ "$(git -C "$np" rev-parse HEAD)" = "$NOTPROTON_COMMIT" ] || { echo "==> $np is not NotProton $NOTPROTON_TAG" >&2; exit 1; }
for f in NOTICE LICENSE.lsteamclient LICENSE.steam-shim; do   # the copies kept here are the pinned release's
  cmp -s "$np/$f" "$here/notproton/$f" || { echo "==> notproton/$f differs from NotProton $NOTPROTON_TAG's" >&2; exit 1; }
done
echo "==> NotProton $NOTPROTON_TAG ($NOTPROTON_COMMIT)"

w=$b/wine
if [ ! -d "$w/.git" ]; then   # built beside, renamed only when whole; one command a line, since set -e skips && lists
  rm -rf "$w.part"
  git init -q "$w.part"
  git -C "$w.part" remote add origin "$WINE_URL"
  git -C "$w.part" fetch -q --depth 1 origin "$WINE_COMMIT"
  git -C "$w.part" checkout -q FETCH_HEAD
  mv "$w.part" "$w"
fi
[ "$(git -C "$w" rev-parse HEAD)" = "$WINE_COMMIT" ] || { echo "==> $w is not at $WINE_COMMIT" >&2; exit 1; }
echo "==> Wine $WINE_COMMIT"

# Madeira's Wine includes ../../../../build/madeira_cfg.h from dlls/ntdll/unix (Madeira's repository has wine/ beside
# build/): the one file of Madeira's source it reaches for, placed where that path lands.
mkdir -p "$b/build"
fetch "$MADEIRA_CFG_URL" "$b/build/madeira_cfg.h" "$MADEIRA_CFG_SHA256"
echo "==> Madeira's build/madeira_cfg.h (v0.1.3)"

fetch "$LLVM_MINGW_URL" "$b/$LLVM_MINGW.tar.xz" "$LLVM_MINGW_SHA256"
if [ ! -d "$b/$LLVM_MINGW" ]; then   # extracted beside, renamed only when whole
  rm -rf "$b/$LLVM_MINGW.part"
  mkdir "$b/$LLVM_MINGW.part"
  tar -xf "$b/$LLVM_MINGW.tar.xz" -C "$b/$LLVM_MINGW.part"
  mv "$b/$LLVM_MINGW.part/$LLVM_MINGW" "$b/$LLVM_MINGW"
  rmdir "$b/$LLVM_MINGW.part"
fi
echo "==> $LLVM_MINGW"

fetch "$MADEIRA_IPA_URL" "$b/Madeira.ipa" "$MADEIRA_IPA_SHA256"
if [ "$(sha "$b/madeira-ntdll.dll")" != "$MADEIRA_NTDLL_SHA256" ]; then   # kept while it matches its pin
  unzip -p "$b/Madeira.ipa" Payload/Madeira.app/arm64ec-windows/ntdll.dll > "$b/madeira-ntdll.dll.part"
  [ "$(sha "$b/madeira-ntdll.dll.part")" = "$MADEIRA_NTDLL_SHA256" ] || { echo "==> Madeira's ntdll.dll does not match its pin" >&2; exit 1; }
  mv "$b/madeira-ntdll.dll.part" "$b/madeira-ntdll.dll"
fi
echo "==> Madeira's ntdll.dll $(sha "$b/madeira-ntdll.dll")"
fetch "$NOTPROTON_ZIP_URL" "$b/NotProton.zip" "$NOTPROTON_ZIP_SHA256"
echo "fetch ok"
