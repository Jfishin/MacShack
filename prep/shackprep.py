#!/usr/bin/env python3
"""Turn a macOS .app into something MacShack can dlopen on iOS.

prep  : thin to arm64, set iOS platform, exec -> dylib, redirect frameworks (unsigned; the host build signs).
embed : copy a prepped app's Mach-Os into host/Guests/<Name> for the host build to embed + sign.
gaps  : list symbols the iOS SDK + shims do not provide.
Game data goes to the device separately with prep/devsync.py. Stdlib + Xcode CLI tools only.
"""
import argparse, os, plistlib, re, shutil, struct, subprocess, sys

# macOS-only frameworks -> shim install names. Anything macOS-only and not listed is an error.
LINK_MAP = {
    "AppKit": "@rpath/libShackAppKit.dylib",
    "Cocoa": "@rpath/libShackAppKit.dylib",
    # The AppKit shim re-exports Foundation and adds the macOS-only Foundation classes (NSAppleEventManager).
    "Foundation": "@rpath/libShackAppKit.dylib",
    "Carbon": "@rpath/libShackCarbon.dylib",
    "CoreServices": "@rpath/libShackCarbon.dylib",
    "CoreGraphics": "@rpath/libShackCG.dylib",
    "CoreVideo": "@rpath/libShackCV.dylib",
    "IOKit": "@rpath/libShackIOKit.dylib",
    "CoreAudio": "@rpath/libShackCoreAudio.dylib",
    "AudioToolbox": "@rpath/libShackAudioToolbox.dylib",
    "AudioUnit": "@rpath/libShackAudioToolbox.dylib",   # iOS has the AU API in AudioToolbox, no AudioUnit.framework
    "OpenGL": "@rpath/libShackOpenGL.dylib",
    "AGL": "@rpath/libShackOpenGL.dylib",
    # ponytail: GameMaker's runner (TetherGeist) links GLUT and binds nothing from it; gaps2 flags any guest that does.
    "GLUT": "@rpath/libShackOpenGL.dylib",
    "Security": "@rpath/libShackSecurity.dylib",
    "AVFoundation": "@rpath/libShackAVFoundation.dylib",
    "libSystem": "@rpath/libShackSystem.dylib",          # /usr/lib/libSystem.B.dylib; see framework_name
    "SwiftUI": "@rpath/libShackSwiftUI.dylib",           # re-exports SwiftUI + macOS-only symbols (NSHostingController)
    # ponytail: InControlNative links ForceFeedback but binds nothing from it; gaps2 flags any guest that does.
    "ForceFeedback": "@rpath/libShackIOKit.dylib",
    # ponytail: Unity's player links these two and binds nothing from them.
    "Quartz": "@rpath/libShackAppKit.dylib",
    # The AppKit shim re-exports QuartzCore and adds the macOS-only CAOpenGLLayer (Godot 4.5 subclasses it).
    "QuartzCore": "@rpath/libShackAppKit.dylib",
    "SecurityFoundation": "@rpath/libShackSecurity.dylib",
    # Umbrella over CoreGraphics and HIServices; games bind HIServices bits (TransformProcessType) the CG shim adds.
    "ApplicationServices": "@rpath/libShackCG.dylib",
    # The CV shim re-exports Metal and adds the macOS-only device observer (Factorio).
    "Metal": "@rpath/libShackCV.dylib",
    # No OpenCL or LDAP on iOS: stubs that report no platform / no server (Factorio's GPU probe, libcurl's LDAP).
    "OpenCL": "@rpath/libShackSystem.dylib",
    "LDAP": "@rpath/libShackSystem.dylib",
    # Both exist on iOS; the shim re-exports them and adds macOS-only symbols (Crimson Desert: HTTPS proxy keys, the Swift
    # 6.2 availability check `_stdlib_isOSVersionAtLeastOrVariantVersion`).
    "CFNetwork": "@rpath/libShackSystem.dylib",
    "libswiftCore": "@rpath/libShackSystem.dylib",
    # macOS's /usr/lib/libcurl.4.dylib; iOS has none. The shim's stubs fail every transfer (Cyberpunk 2077 plays offline).
    "libcurl": "@rpath/libShackSystem.dylib",
}
# Frameworks that do not exist on iOS at all. Presence without a LINK_MAP entry aborts.
MACOS_ONLY = {"AppKit", "Cocoa", "Carbon", "AudioUnit", "ApplicationServices", "OpenGL", "AGL", "ForceFeedback",
              "CoreWLAN", "DiscRecording", "InstallerPlugins", "Quartz", "ScreenSaver", "SecurityFoundation",
              "SecurityInterface", "OpenCL", "LDAP"}

MH_MAGIC_64, FAT_MAGIC = 0xFEEDFACF, 0xCAFEBABE
MH_EXECUTE, MH_DYLIB = 2, 6
MH_PIE, MH_NO_REEXPORTED_DYLIBS = 0x200000, 0x100000
LC_SEGMENT_64, LC_ID_DYLIB, LC_LOAD_DYLINKER, LC_LOAD_DYLIB = 0x19, 0xD, 0xE, 0xC

class PrepError(Exception): pass

def run(*cmd): return subprocess.check_output(cmd, text=True, errors="replace", stderr=subprocess.STDOUT)

def is_macho(path):
    if not os.path.isfile(path) or os.path.islink(path): return False
    with open(path, "rb") as f: m = f.read(4)
    if len(m) < 4: return False
    be, = struct.unpack(">I", m)
    le, = struct.unpack("<I", m)
    return be in (FAT_MAGIC, 0xCAFEBABF) or le == MH_MAGIC_64  # 0xCAFEBABF = FAT_MAGIC_64

def machos_in(app):
    for root, _, files in os.walk(app):
        if ".dSYM" in root: continue   # debug symbols: never loaded, and dyld_info crashes on some
        for fn in files:
            p = os.path.join(root, fn)
            if is_macho(p): yield p

def has_arm64(path):
    return "arm64" in run("lipo", "-archs", path).split()

def main_executable(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return os.path.join(app, "Contents", "MacOS", plistlib.load(f)["CFBundleExecutable"])

def thin_arm64(path):
    # ponytail: "arm64" != "arm64e" in lipo's arch names, so an arm64e-only binary is
    # already rejected here as having no arm64 slice; no separate arm64e check needed.
    archs = run("lipo", "-archs", path).split()
    if "arm64" not in archs: raise PrepError(f"{path}: no arm64 slice ({archs})")
    if len(archs) > 1: run("lipo", "-thin", "arm64", path, "-output", path)
    if re.search(r"cryptid\s+1", run("otool", "-l", path)): raise PrepError(f"{path}: FairPlay encrypted")

def set_ios_platform(path, minos="16.0", sdk="26.4"):
    run("vtool", "-set-build-version", "ios", minos, sdk, "-replace", "-output", path, path)

def exec_to_dylib(path):
    """MH_EXECUTE -> MH_DYLIB the LiveContainer way: flip filetype/flags, shrink __PAGEZERO to
    one page, turn LC_LOAD_DYLINKER (unused in a dylib) into LC_ID_DYLIB. LC_MAIN is kept."""
    with open(path, "r+b") as f:
        hdr = bytearray(f.read(32))
        magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack("<IiiIIIII", hdr)
        if magic != MH_MAGIC_64: raise PrepError(f"{path}: not a thin 64-bit Mach-O")
        if filetype != MH_EXECUTE: return
        flags = (flags | MH_NO_REEXPORTED_DYLIBS) & ~MH_PIE
        f.seek(0); f.write(struct.pack("<IiiIIIII", magic, cputype, cpusub, MH_DYLIB, ncmds, sizeofcmds, flags, 0))
        off, seen_id = 32, False
        for _ in range(ncmds):
            f.seek(off); cmd, cmdsize = struct.unpack("<II", f.read(8))
            if cmd == LC_SEGMENT_64:
                f.seek(off + 8); segname = f.read(16).rstrip(b"\0")
                if segname == b"__PAGEZERO":
                    f.seek(off + 24); f.write(struct.pack("<QQ", 0x100000000 - 0x4000, 0x4000))
            elif cmd == LC_LOAD_DYLINKER and not seen_id:
                name = b"guest\0"
                body = struct.pack("<IIIIII", LC_ID_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000) + name
                # ponytail: assumes clang's default dyld path gives a 32-byte LC_LOAD_DYLINKER,
                # comfortably >= our body; still verify rather than trust it silently.
                if cmdsize < len(body):
                    raise PrepError(f"{path}: LC_LOAD_DYLINKER too small ({cmdsize} bytes) for LC_ID_DYLIB")
                f.seek(off); f.write(body.ljust(cmdsize, b"\0")); seen_id = True
            off += cmdsize
        if not seen_id: raise PrepError(f"{path}: no LC_LOAD_DYLINKER to repurpose as LC_ID_DYLIB")

def link_libsystem(path):
    """iOS dyld rejects a dylib with no LC_LOAD_DYLIB (Unity's Burst output links nothing). Add libSystem, making
    room by shortening LC_ID_DYLIB's name (Burst's is a long Windows build path; dyld never reads it)."""
    with open(path, "r+b") as f:
        data = bytearray(f.read())
    magic, _, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data)
    if magic != MH_MAGIC_64 or filetype != MH_DYLIB: return False
    cmds, off, first_sect = [], 32, len(data)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd & 0x7FFFFFFF in (0xC, 0x18, 0x1F, 0x20, 0x23): return False   # any LC_*_DYLIB load
        if cmd == LC_SEGMENT_64:
            nsects, = struct.unpack_from("<I", data, off + 64)
            for i in range(nsects):
                so, = struct.unpack_from("<I", data, off + 72 + i * 80 + 48)
                if so: first_sect = min(first_sect, so)
        body = bytes(data[off:off + size])
        if cmd == LC_ID_DYLIB: body = struct.pack("<II", LC_ID_DYLIB, 32) + body[8:24] + b"burst\0\0\0"
        cmds.append(body)
        off += size
    name = b"/usr/lib/libSystem.B.dylib\0"
    size = (24 + len(name) + 7) & ~7
    cmds.append(struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0"))
    blob = b"".join(cmds)
    if 32 + len(blob) > first_sect: raise PrepError(f"{path}: no header room to link libSystem")
    struct.pack_into("<II", data, 16, len(cmds), len(blob))
    data[32:32 + max(len(blob), sizeofcmds)] = blob.ljust(max(len(blob), sizeofcmds), b"\0")
    with open(path, "wb") as f: f.write(data)
    return True

def linked_libs(path):
    return [ln.split()[0] for ln in run("otool", "-L", path).splitlines()[1:] if ln.strip()]

def framework_name(p):
    """Framework name of a load path; libSystem counts as one so LINK_MAP can point it at its shim."""
    m = re.search(r"/([^/]+)\.framework/", p)
    if m: return m.group(1)
    m = re.fullmatch(r"/usr/lib/swift/(lib[^/]+)\.dylib", p)   # the OS Swift runtime (iOS ships it too)
    if m: return m.group(1)
    if p == "/usr/lib/libcurl.4.dylib": return "libcurl"
    return "libSystem" if p == "/usr/lib/libSystem.B.dylib" else None

def rewrite_links(path, link_map, exe_dir=None):
    """exe_dir: the guest's Contents/MacOS. @executable_path would resolve to the host app, so those links
    become @loader_path-relative ones that reach the same file inside the guest tree."""
    changed, missing = [], []
    # Search paths too: @executable_path in an LC_RPATH would name the host app, not the guest's MacOS folder.
    if exe_dir:
        for rp in re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", run("otool", "-l", path)):
            if rp.startswith("@executable_path"):
                rel = os.path.relpath(exe_dir, os.path.dirname(path))
                new = "@loader_path/" + os.path.normpath(os.path.join(rel, rp[len("@executable_path/"):] or "."))
                run("install_name_tool", "-rpath", rp, new, path); changed.append(rp)
    libs = linked_libs(path); used = set(libs)
    for old in libs:
        if exe_dir and old.startswith("@executable_path/"):
            rel = os.path.relpath(exe_dir, os.path.dirname(path))
            new = "@loader_path/" + os.path.normpath(os.path.join(rel, old[len("@executable_path/"):]))
            run("install_name_tool", "-change", old, new, path); changed.append(old); continue
        fw = framework_name(old)
        if not fw: continue
        if fw in link_map: new = link_map[fw]
        elif fw in MACOS_ONLY: missing.append(fw); continue
        else: new = re.sub(r"\.framework/Versions/[A-Z]/", ".framework/", old)
        # dyld rejects a path linked twice (Cocoa and AppKit share a shim). Deleting the load command
        # would shift the dylib ordinals binds use, so respell it: "@rpath/./x" is the same file.
        while new != old and new in used:
            if not new.startswith("@rpath/"): raise PrepError(f"{path}: {old} -> {new} duplicates a linked dylib")
            new = new.replace("@rpath/", "@rpath/./", 1)
        used.add(new)
        if new != old:
            run("install_name_tool", "-change", old, new, path); changed.append(old)
    if missing: raise PrepError(f"{path}: macOS-only frameworks with no shim mapping: {sorted(set(missing))}")
    return changed

def copy_code(app, dest):
    """Copy only the Mach-Os and Contents/Info.plist of app into dest, same relative paths. Every .framework also gets
    an Info.plist at its top level (iOS's shallow layout): Xcode refuses to embed a framework folder without one."""
    for src in [*machos_in(app), os.path.join(app, "Contents", "Info.plist")]:
        dst = os.path.join(dest, os.path.relpath(src, app))
        os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copy2(src, dst)
    for root, dirs, _ in os.walk(dest):
        for d in dirs:
            if not d.endswith(".framework"): continue
            rel = os.path.relpath(os.path.join(root, d), dest)
            for cand in ("Info.plist", "Resources/Info.plist", "Versions/A/Resources/Info.plist", "Versions/Current/Resources/Info.plist"):
                src = os.path.join(app, rel, cand)
                if os.path.isfile(src): shutil.copy2(src, os.path.join(root, d, "Info.plist")); break
            flatten_framework(os.path.join(root, d))

def flatten_framework(fw):
    """macOS deep layout (Versions/A/X) -> iOS shallow (X at the top): iOS only loads a framework binary signed as part
    of its bundle, and codesign signs only the shallow form. Links to X.framework/Versions/A/X are already rewritten to
    X.framework/X (rewrite_links). ponytail: a Mach-O nested deeper (Versions/A/Frameworks/...) moves up one level with
    the rest; an @loader_path link that climbs out of the framework would then be off by two."""
    versions = os.path.join(fw, "Versions")
    if not os.path.isdir(versions) or os.path.islink(versions): return
    cur = next((os.path.join(versions, v) for v in ("A", "Current") if os.path.isdir(os.path.join(versions, v))), None)
    if cur:
        for dp, _, fs in os.walk(cur):
            for f in fs:
                src = os.path.join(dp, f); dst = os.path.join(fw, os.path.relpath(src, cur))
                if not os.path.exists(dst): os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copy2(src, dst)
    shutil.rmtree(versions)

def prep_bundle(app, out, link_map=LINK_MAP, binaries_only=False):
    """binaries_only: skip the data (e.g. 39 GB of paks already on the device); prep just the code."""
    if os.path.exists(out): shutil.rmtree(out)
    if binaries_only: copy_code(app, out)
    else: shutil.copytree(app, out, symlinks=True)
    main = main_executable(out)
    for p in machos_in(out):
        if p != main and not has_arm64(p):
            # An Intel-only plugin (x64 Bink, a crash reporter's old Swift runtime) can never load on iOS, and an
            # x86-only Mach-O inside the host bundle risks the install. Drop it from this copy; the game fails only if
            # it actually loads it. The main executable still raises below.
            os.remove(p); print(f"note: no arm64 slice, dropped: {os.path.relpath(p, out)}", file=sys.stderr); continue
        thin_arm64(p); set_ios_platform(p)
        if os.path.realpath(p) == os.path.realpath(main): exec_to_dylib(p)
        link_libsystem(p)
        rewrite_links(p, link_map, os.path.dirname(main))
    shutil.rmtree(os.path.join(out, "Contents", "_CodeSignature"), ignore_errors=True)   # stale seal from the Mac build
    return out

def embed(app, guests_dir):
    """Copy the prepped app's Mach-Os + Info.plist to guests_dir/<Name>/ (same relative paths);
    the host build embeds and signs that tree, the data stays in Documents/Games/<Name>.app."""
    dest = os.path.join(guests_dir, os.path.splitext(os.path.basename(os.path.normpath(app)))[0])
    shutil.rmtree(dest, ignore_errors=True)
    copy_code(app, dest)
    return dest

_TBD_LIST = re.compile(r"(symbols|weak-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[(.*?)\]", re.S)

def _tbd_symbols(text):
    out = set()
    for kind, body in _TBD_LIST.findall(text):
        for tok in re.split(r"[\s,]+", body):
            tok = tok.strip("'\"")
            if not tok: continue
            if kind == "objc-classes": out.add("_OBJC_CLASS_$_" + tok); out.add("_OBJC_METACLASS_$_" + tok)
            elif kind == "objc-ivars": out.add("_OBJC_IVAR_$_" + tok)
            elif kind == "objc-eh-types": out.add("_OBJC_EHTYPE_$_" + tok)
            else: out.add(tok)
    return out

def sdk_exports(sdk_path):
    """Every symbol any .tbd in the SDK exports, in nm spelling."""
    out = set()
    for base in ("System/Library/Frameworks", "System/Library/PrivateFrameworks", "usr/lib"):
        for root, _, files in os.walk(os.path.join(sdk_path, base)):
            for fn in files:
                if not fn.endswith(".tbd"): continue
                with open(os.path.join(root, fn), errors="ignore") as f: text = f.read()
                out |= _tbd_symbols(text)
    return out

def exported_by(paths):
    # The export trie, as dyld reads it: nm -gU only sees the symbol table, which some shipped dylibs strip
    # (Hades II's Bink library exports ~60 functions and has no symbol table entries at all).
    out = set()
    for p in paths:
        for ln in run("xcrun", "dyld_info", "-arch", "arm64", "-exports", p).splitlines():
            parts = ln.split()
            if len(parts) >= 2 and parts[0].startswith("0x") and parts[1].startswith("_"): out.add(parts[1])
    return out

def undefined_in(path):
    return {ln.split()[-1] for ln in run("nm", "-u", path).splitlines() if ln.strip()}

def gap_report(app, sdk_path, shim_dirs):
    provided = sdk_exports(sdk_path)
    shims = [os.path.join(d, f) for d in shim_dirs for f in os.listdir(d) if f.endswith(".dylib")]
    provided |= exported_by(shims)
    bundled = list(machos_in(app))
    provided |= exported_by(bundled)          # a game's own dylibs provide symbols to each other
    return {p: sorted(undefined_in(p) - provided) for p in bundled}

REEXPORTS = {
    "libShackAppKit.dylib": ["UIKit", "Foundation", "QuartzCore"],
    "libShackCarbon.dylib": ["CoreServices", "libSystem"],
    "libShackCG.dylib": ["CoreGraphics"],
    "libShackCV.dylib": ["CoreVideo", "Metal"],
    "libShackIOKit.dylib": ["IOKit"],
    "libShackCoreAudio.dylib": ["CoreAudio"],
    "libShackAudioToolbox.dylib": ["AudioToolbox"],
    "libShackOpenGL.dylib": [],
    "libShackSecurity.dylib": ["Security"],
    "libShackAVFoundation.dylib": ["AVFoundation"],
    "libShackSystem.dylib": ["libSystem", "CFNetwork", "libswiftCore"],
    "libShackSwiftUI.dylib": ["SwiftUI"],
}

def bind_targets(macho):
    """{library: {symbol: is_weak}} from `dyld_info -fixups`."""
    text = run("xcrun", "dyld_info", "-arch", "arm64", "-fixups", macho)   # bundled dylibs are fat; only the arm64 slice loads
    return parse_fixups(text)

def parse_fixups(text):
    """{library: {symbol: is_weak}} from `dyld_info -fixups` text (pure, unit-testable).

    Target column is normally `lib/symbol`, but a vtable/typeinfo bind carries an
    addend (`lib/symbol + 0x10`) and either form may carry a trailing `[weak-import]`.
    """
    out = {}
    for ln in text.splitlines():
        t = ln.split()
        if len(t) < 5 or "bind" not in t[3]: continue
        rest = t[4:]
        weak = rest[-1] == "[weak-import]"
        if weak: rest = rest[:-1]
        if len(rest) >= 3 and rest[-2] == "+": rest = rest[:-2]   # strip " + 0x10" addend
        tgt = rest[0]
        if "/" not in tgt: continue
        lib, sym = tgt.rsplit("/", 1)
        # ponytail: dyld_info mis-decodes the tail of some LC_DYLD_INFO bind streams (Unity's libmonobdwgc) into
        # garbage names on these pseudo-ordinals; `objdump --macho --bind` shows no such binds. Skip them.
        if lib in ("<invalid-lib-ordinal>", "<this-image>"): continue
        out.setdefault(lib, {})[sym] = weak
    return out

def framework_exports(sdk_path, name, _seen=None):
    """Exports of a framework (or usr/lib dylib) including its re-exported libraries, as dyld resolves them.
    A .tbd inlines some re-exports as extra documents; the others (AVFoundation -> AVFAudio) are followed here."""
    seen = _seen if _seen is not None else set()
    if name in seen: return set()
    seen.add(name)
    for base in ("System/Library/Frameworks", "System/Library/PrivateFrameworks", "usr/lib", "usr/lib/swift"):
        p = os.path.join(sdk_path, base, name + ".tbd") if base.startswith("usr/lib") else os.path.join(sdk_path, base, name + ".framework", name + ".tbd")
        if os.path.exists(p): break
        if base == "usr/lib" and os.path.exists(p[:-4] + ".0.tbd"): p = p[:-4] + ".0.tbd"; break   # libbz2.1 -> libbz2.1.0.tbd
    else: return set()
    with open(p, errors="ignore") as f: text = f.read()
    out = _tbd_symbols(text)
    for body in re.findall(r"\blibraries:\s*\[(.*?)\]", text, re.S):
        for lib in re.findall(r"'([^']+)'", body):
            fw = framework_name(lib)
            if fw: out |= framework_exports(sdk_path, fw, seen)
    return out

def gap_report2(app, sdk_path, shim_dir, link_map=LINK_MAP, reexports=REEXPORTS):
    everything = list(machos_in(app))
    bundled = [p for p in everything if has_arm64(p)]; bundled_exports = exported_by(bundled)
    shim_exports = {}
    if shim_dir:
        for f in os.listdir(shim_dir):
            if f.endswith(".dylib"): shim_exports[f] = exported_by([os.path.join(shim_dir, f)])
    # dyld_info reports a bind's *current* load-command name: once rewrite_links has already
    # repointed a macOS-only framework at its shim, a symbol that originally bound from e.g. AppKit
    # shows up as the shim's own basename ("libShackAppKit"). Normalize that back to the framework
    # name (first link_map key mapping to that shim) so matching/reporting is the same whether this
    # runs on a raw .app or one already prepped.
    shim_label = {}
    for fw, shim in link_map.items():
        shim_label.setdefault(os.path.splitext(os.path.basename(shim))[0], fw)
    cache = {}
    def provided_by(lib):
        if lib in cache: return cache[lib]
        s = set()
        shim = link_map.get(lib)
        if shim:
            base = os.path.basename(shim)
            s |= shim_exports.get(base, set())
            for fw in reexports.get(base, []): s |= framework_exports(sdk_path, fw)
        elif lib in ("<flat-namespace>", "<weak-def-coalesce>"):
            # Dynamic lookup and weak-definition coalescing resolve against loaded images.
            s |= sdk_exports(sdk_path)
            for e in shim_exports.values(): s |= e
        else:
            s |= framework_exports(sdk_path, lib)
        cache[lib] = s; return s
    report = {}
    for p in bundled:
        hard, weak = [], []
        for raw_lib, syms in bind_targets(p).items():
            lib = shim_label.get(raw_lib, raw_lib)
            prov = provided_by(lib) | bundled_exports
            for sym, is_weak in syms.items():
                if sym in prov: continue
                (weak if is_weak else hard).append(f"{lib}/{sym}")
        report[p] = {"hard": sorted(hard), "weak": sorted(weak)}
    for p in everything:
        if p not in report: report[p] = {"hard": ["<no arm64 slice: cannot run on iOS>"], "weak": []}
    return report

def cli(argv):
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prep"); p.add_argument("app"); p.add_argument("out")
    p.add_argument("--binaries-only", action="store_true", help="prep only Mach-Os + Info.plist (data already on device)")
    e = sub.add_parser("embed"); e.add_argument("app")
    e.add_argument("--guests", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "host", "Guests"))
    g = sub.add_parser("gaps"); g.add_argument("app"); g.add_argument("--shims", action="append", default=[])
    g2 = sub.add_parser("gaps2"); g2.add_argument("app"); g2.add_argument("--shims")
    a = ap.parse_args(argv)
    if a.cmd == "prep":
        print("prepped:", prep_bundle(a.app, a.out, binaries_only=a.binaries_only))
    elif a.cmd == "embed": print("embedded:", embed(a.app, a.guests))
    elif a.cmd == "gaps":
        sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").strip()
        for p, missing in gap_report(a.app, sdk, a.shims).items():
            print(f"{os.path.relpath(p, a.app)}: {len(missing)} missing")
            for s in missing: print("   ", s)
    elif a.cmd == "gaps2":
        sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").strip()
        for p, r in gap_report2(a.app, sdk, a.shims).items():
            print(f"{os.path.relpath(p, a.app)}: hard {len(r['hard'])} / weak {len(r['weak'])}")
            for s in r["hard"]: print("    ", s)
            for s in r["weak"]: print("    weak", s)

if __name__ == "__main__":
    try: cli(sys.argv[1:])
    except PrepError as e: print("error:", e, file=sys.stderr); sys.exit(1)
