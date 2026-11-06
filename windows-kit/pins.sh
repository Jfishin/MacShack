# What the Windows kit is built from (windows-kit/release.sh), each at a public source and a pin; every release's
# SOURCE file repeats these. Sourced by the kit's scripts.
KIT_VERSION=2
NOTPROTON_URL=https://github.com/NotProtonNot/NotProton.git
NOTPROTON_TAG=v1.0.3
NOTPROTON_COMMIT=73a18c34749c3d9b8612fafb51ac5e85ed8a5038
NOTPROTON_ZIP_URL=https://github.com/NotProtonNot/NotProton/releases/download/v1.0.3/NotProton.zip   # steam.exe compare
NOTPROTON_ZIP_SHA256=972a5f41ab861b287ae173ef57fadc8ebcecd5e98cae0806e33ad1e57617ab24
WINE_URL=https://github.com/willfaust/wine.git
MADEIRA_VERSION=0.2.0
WINE_COMMIT=80c859a76e1073bd41095b1b0abc43135efdd475   # the commit Madeira v0.2.0 pins (its wine submodule)
LLVM_MINGW=llvm-mingw-20260421-ucrt-macos-universal   # Madeira's toolchain (its docs/BUILDING.md)
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$LLVM_MINGW.tar.xz
LLVM_MINGW_SHA256=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
MADEIRA_IPA_URL=https://github.com/willfaust/Madeira/releases/download/v$MADEIRA_VERSION/Madeira-$MADEIRA_VERSION.ipa   # its ntdll.dll
MADEIRA_IPA_SHA256=7cdab35d6029b9a7701775ac794ac2674cac501ec6503465775e7a35ae046154
MADEIRA_NTDLL_SHA256=596ba0e4853e56ed61e006a20651edfb86cf49162bb0ac9bedc91d5873d43ada   # its arm64ec-windows/ntdll.dll: the detour is made for this file
MADEIRA_COMMIT=5fda6a0e9543e5de1df010aff35748ab913fd0d9   # Madeira v0.2.0 (its tag's commit)
MADEIRA_CFG_URL=https://raw.githubusercontent.com/willfaust/Madeira/$MADEIRA_COMMIT/build/madeira_cfg.h
MADEIRA_CFG_SHA256=4ed1e27e3fe8ed47d0faeaef6da611c0961f41932482abd3211d8799eae22006
