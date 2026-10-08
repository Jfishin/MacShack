# What the Windows kit is built from (windows-kit/release.sh), each at a public source and a pin; every release's
# SOURCE file repeats these. Sourced by the kit's scripts.
KIT_VERSION=1
NOTPROTON_URL=https://github.com/NotProtonNot/NotProton.git
NOTPROTON_TAG=v1.0.3
NOTPROTON_COMMIT=73a18c34749c3d9b8612fafb51ac5e85ed8a5038
NOTPROTON_ZIP_URL=https://github.com/NotProtonNot/NotProton/releases/download/v1.0.3/NotProton.zip   # steam.exe compare
NOTPROTON_ZIP_SHA256=972a5f41ab861b287ae173ef57fadc8ebcecd5e98cae0806e33ad1e57617ab24
WINE_URL=https://github.com/willfaust/wine.git
WINE_COMMIT=4f5b19718f4de88ecc5cb0dc08b119497a67ba8f   # the commit Madeira v0.1.3 pins (its wine submodule)
LLVM_MINGW=llvm-mingw-20260421-ucrt-macos-universal   # Madeira's toolchain (its docs/BUILDING.md)
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$LLVM_MINGW.tar.xz
LLVM_MINGW_SHA256=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
MADEIRA_IPA_URL=https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa   # its ntdll.dll
MADEIRA_IPA_SHA256=71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0
MADEIRA_NTDLL_SHA256=59c1523792cef4f5d4cbffdd62d8c7d9682be8c718fb7d65db2dcf711e3f7e51   # its arm64ec-windows/ntdll.dll: the detour is made for this file
MADEIRA_COMMIT=4e9d45a74294cd820120791c4b3f2b79adf4fc70   # Madeira v0.1.3 (its tag)
MADEIRA_CFG_URL=https://raw.githubusercontent.com/willfaust/Madeira/$MADEIRA_COMMIT/build/madeira_cfg.h
MADEIRA_CFG_SHA256=10a6a115913ccd66f7c79868e23f17bd4343a6abc408ad59466b567ea0a5ad50
