#!/usr/bin/env python3
"""The Steam client's iOS link gaps with libShackSteamClient in place (want: hard 0 for the images Steam loads).
Same map as SteamLinkMap() in host/ShackSteamProbe.m.
  prep/steam-onehost/check_gaps.py <Steam.AppBundle/Steam> <MacShack.app/Frameworks>
"""
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
import shackprep

STEAM_MAP = ["AppKit", "Cocoa", "Foundation", "Quartz", "QuartzCore", "Carbon", "CoreServices", "CoreGraphics",
             "ApplicationServices", "CoreVideo", "Metal", "IOKit", "ForceFeedback", "Security", "SecurityFoundation",
             "libSystem", "CFNetwork", "OpenGL", "CoreText", "CoreFoundation", "VideoToolbox", "AuthenticationServices",
             "SafariServices", "DiskArbitration", "OpenDirectory", "IOBluetooth", "CoreWLAN", "SecurityInterface",
             "ServiceManagement", "libcups", "libpmenergy", "libpmsample"]   # dyld_info names /usr/lib/libcups.2 "libcups"
SHIMS = ["AppKit", "Carbon", "CG", "CV", "IOKit", "Security", "System", "OpenGL"]   # what libShackSteamClient re-exports
FRAMEWORKS = ["CoreText", "CoreFoundation", "VideoToolbox", "AuthenticationServices", "SafariServices"]
LOADED = {"steam_osx", "steamui.dylib", "steamclient.dylib", "vgui2_s.dylib", "chromehtml.dylib", "friendsui.dylib",
          "steamservice.dylib", "filesystem_stdio.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib", "libSDL3.dylib",
          "libaudio.dylib", "libsteaminput.dylib", "libusb-1.0.0.dylib", "libvideo.dylib", "libavcodec.62.dylib",
          "Breakpad", "breakpadUtilities.dylib", "crashhandler.dylib", "ipcserver", "Steam Helper",
          "Chromium Embedded Framework"}

def main(app, shims):
    link_map = dict(shackprep.LINK_MAP)
    link_map.update({name: "@rpath/libShackSteamClient.dylib" for name in STEAM_MAP})
    reexports = dict(shackprep.REEXPORTS)
    reexports["libShackSteamClient.dylib"] = sorted({fw for s in SHIMS for fw in shackprep.REEXPORTS[f"libShack{s}.dylib"]} | set(FRAMEWORKS))
    exported_by = shackprep.exported_by
    def with_reexported_shims(paths):   # the shim's own exports plus those of the shims it re-exports
        out = set()
        for p in paths:
            out |= exported_by([p])
            if os.path.basename(p) == "libShackSteamClient.dylib":
                out |= exported_by([os.path.join(shims, f"libShack{s}.dylib") for s in SHIMS])
        return out
    shackprep.exported_by = with_reexported_shims
    report = shackprep.gap_report2(app, shackprep.sdk_path() if hasattr(shackprep, "sdk_path") else
                                   os.popen("xcrun --sdk iphoneos --show-sdk-path").read().strip(), shims, link_map, reexports)
    total = 0
    for path, gaps in sorted(report.items()):
        if os.path.basename(path) not in LOADED: continue
        total += len(gaps["hard"])
        for g in gaps["hard"]: print(f"{os.path.relpath(path, app)}: {g}")
    print(f"hard gaps in the images Steam loads: {total}")
    return 1 if total else 0

if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
