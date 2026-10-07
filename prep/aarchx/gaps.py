#!/usr/bin/env python3
"""Intel (x86_64) game gap report, the AArchX counterpart of `shackprep.py gaps2`.

For every x86_64 Mach-O in a game (main executable, plugins, dylibs) it lists each import and sorts it by what
native mode would do with it:

  ok             a `fn`/`data`/`special` record whose host symbol MacShack's shims or the iOS SDK export
  host-missing   a record whose host symbol nothing exports: a call aborts ("bridge: ... not implemented"),
                 a class or constant is a load-time miss (a logged stub with OCERZ_STUB_MISSING)
  stub           the database only has a `stub` record: a call aborts
  not-in-db      the database has no entry (or no file for the library): a logged stub

The host library is the one ShackPrep's LinkMap picks (a shim and what it re-exports) or the iOS framework of the same
name; an iOS .tbd can list a private symbol dlsym still cannot reach, so "ok" is a good bet, not a proof.
Needs the databases (`make apis` in vendor/AArchX) and a built MacShack.app for the shims.

  python3 prep/aarchx/gaps.py "Game.app" [--apis vendor/AArchX/runtime/apis/macos/27.0] [--shims <MacShack.app>/Frameworks]
"""
import argparse, collections, glob, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def short(install):
    base = os.path.basename(install)
    return re.sub(r"(\.\d+)*\.dylib$|\.tbd$", "", base)


def load_db(apis):
    db = {}
    for path in glob.glob(os.path.join(apis, "*.api")):
        recs, lib = {}, None
        for line in open(path, errors="replace"):
            p = line.split()
            if not p or p[0].startswith("#"):
                continue
            if p[0] == "library":
                lib = p[1]
            elif p[0] in ("fn", "data", "special", "stub", "var", "inplace") and len(p) >= 2:
                recs[p[1]] = p
        if lib:
            db[short(lib)] = recs
    return db


# framework -> shim, as ShackPrep.m's LinkMap(): the host library an install name resolves to
LINK_MAP = {"AppKit": "AppKit", "Cocoa": "AppKit", "Foundation": "AppKit", "Carbon": "Carbon", "CoreServices": "Carbon",
            "CoreGraphics": "CG", "CoreVideo": "CV", "IOKit": "IOKit", "CoreAudio": "CoreAudio", "AudioToolbox": "AudioToolbox",
            "AudioUnit": "AudioToolbox", "OpenGL": "OpenGL", "AGL": "OpenGL", "Security": "Security", "AVFoundation": "AVFoundation",
            "libSystem": "System", "SwiftUI": "SwiftUI", "ForceFeedback": "IOKit", "Quartz": "AppKit", "QuartzCore": "AppKit",
            "SecurityFoundation": "Security", "ApplicationServices": "CG", "Metal": "CV", "OpenCL": "System", "LDAP": "System"}


class Host:
    """What dlsym on the host library an install name maps to can find: the shim's own exports plus what it re-exports,
    or the iOS framework's .tbd (and the libraries that .tbd re-exports)."""

    def __init__(self, shims, sdk):
        self.shims, self.sdk, self.cache = shims, sdk, {}

    def tbd(self, install, seen=None):
        seen = seen if seen is not None else set()
        if install in seen:
            return set()
        seen.add(install)
        path = self.sdk + os.path.splitext(install)[0] + ".tbd"
        if not os.path.exists(path):
            m = re.match(r"(.*)/Versions/[A-Z]/(.*)", install)          # a macOS install name into the flat iOS layout
            path = self.sdk + os.path.splitext(m.group(1) + "/" + m.group(2))[0] + ".tbd" if m else path
        if not os.path.exists(path):
            return set()
        text = open(path, errors="replace").read()
        names = set(re.findall(r"(?<![\w$.])_[A-Za-z0-9_$.]+", text))
        for block in re.findall(r"objc-classes:\s*\[([^\]]*)\]", text, re.S):
            for c in re.findall(r"[A-Za-z0-9_$.]+", block):
                names.update(("_OBJC_CLASS_$_" + c, "_OBJC_METACLASS_$_" + c))
        for block in re.findall(r"reexported-libraries:.*?libraries:\s*\[([^\]]*)\]", text, re.S):
            for lib in re.findall(r"/[A-Za-z0-9_/.+-]+", block):
                names |= self.tbd(lib, seen)
        return names

    def shim(self, name):
        dylib = os.path.join(self.shims, f"libShack{name}.dylib")
        if not os.path.exists(dylib):
            return set()
        out = subprocess.run(["nm", "-gU", "-arch", "arm64", dylib], capture_output=True, text=True).stdout
        names = {l.split()[-1] for l in out.splitlines() if l.strip()}
        lc = subprocess.run(["otool", "-arch", "arm64", "-l", dylib], capture_output=True, text=True).stdout
        for m in re.finditer(r"cmd LC_REEXPORT_DYLIB.*?name (\S+)", lc, re.S):
            names |= self.tbd(m.group(1))
        return names

    def exports(self, lib):
        if lib not in self.cache:
            shim = LINK_MAP.get(lib)
            if shim:
                self.cache[lib] = self.shim(shim)
            else:
                self.cache[lib] = self.tbd(f"/System/Library/Frameworks/{lib}.framework/{lib}") | self.tbd(f"/usr/lib/{lib}.dylib")
        return self.cache[lib]


def imports(path):
    out = subprocess.run(["xcrun", "dyld_info", "-arch", "x86_64", "-imports", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"\s+(\S+)(\s+\[weak-import\])?\s+\(from ([^)]+)\)", line)
        if m:
            yield m.group(1), m.group(3), bool(m.group(2))


def x86_machos(app):
    for base, _, files in os.walk(app):
        for f in files:
            p = os.path.join(base, f)
            if os.path.islink(p) or os.path.getsize(p) < 4096:
                continue
            try:
                with open(p, "rb") as fh:
                    magic = fh.read(4)
            except OSError:
                continue
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                out = subprocess.run(["lipo", "-archs", p], capture_output=True, text=True).stdout
                if "x86_64" in out.split():
                    yield p


def classify(sym, lib, db, host):
    recs = db.get(lib)
    if recs is None:
        return "not-in-db", "no database for " + lib
    rec = recs.get(sym)
    if rec is None:
        return "not-in-db", lib
    kind = rec[0]
    if kind == "special":
        return "ok", kind
    if kind == "stub":
        return "stub", " ".join(rec[2:])
    if kind in ("fn", "data") and len(rec) >= 3:
        return ("ok", kind) if "_" + rec[2] in host.exports(lib) else ("host-missing", kind + " " + rec[2])
    return "ok", kind


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app")
    ap.add_argument("--apis", default=os.path.join(ROOT, "vendor/AArchX/runtime/apis/macos/27.0"))
    ap.add_argument("--shims", default=os.path.join(ROOT, "build/Build/Products/Release-iphoneos/MacShack.app/Frameworks"))
    a = ap.parse_args()
    sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
    db, host = load_db(a.apis), Host(a.shims, sdk)
    print(f"{len(db)} databases", file=sys.stderr)
    for path in x86_machos(a.app):
        rows = collections.defaultdict(list)
        for sym, lib, weak in imports(path):
            if lib in ("flat-namespace",) or lib.startswith("@"):
                continue
            cat, why = classify(sym, lib, db, host)
            rows[cat].append((lib, sym, why, weak))
        print(f"\n{os.path.relpath(path, a.app)}: " + ", ".join(f"{k} {len(v)}" for k, v in sorted(rows.items())))
        for cat in ("stub", "host-missing", "not-in-db"):
            for lib, sym, why, weak in sorted(rows.get(cat, [])):
                print(f"  {cat:12} {sym}  ({lib}; {why}{'; weak' if weak else ''})")


if __name__ == "__main__":
    main()
