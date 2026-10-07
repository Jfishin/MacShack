#!/usr/bin/env python3
"""Static compatibility audit: what macOS API do games use that iOS plus MacShack's shims lack? (research prototype)

For every Mach-O in the given bundles (arm64 slice if present, else x86_64):
  - Objective-C selectors it sends (its __objc_selrefs: plain pointers, chained fixups, arm64e auth rebases),
    minus selectors its own classes implement (delegate callbacks, overrides)
  - a selector is a system API when a public macOS class declares it (class names from the macOS SDK headers,
    methods from a macOS runtime dump); it is covered when any declaring (class, +/-) resolves on the iOS runtime
    dump plus the shims' ObjC metadata, through the superclass chain
  - uncovered: "soft" when a declaring class is a shim class with the safety net (answers 0/nil and logs),
    "hard" otherwise (unrecognized selector: an exception on arm64, an AArchX bridge abort on x86)
  - protocol API with no class declarer (Metal): hard when the macOS SDK marks it API_UNAVAILABLE(ios) and
    ShackMetal.m does not add it at runtime
  - C symbols nothing provides: shackprep.py's arm64 gap report, gaps.py's AArchX classification for x86 files
  - engine and "draws with OpenGL only" guesses (arm64 GL-only games need SHACK_OPENGL=1)

  ./run_dumps.sh        # once per Xcode/iOS update: mac.tsv, ios.tsv (Simulator), mac_public_classes.txt
  python3 compat_audit.py --shims build/Build/Products/Release-iphoneos/MacShack.app --json out.json <Game.app>...
  python3 compat_audit.py --self-test
stdlib only; Mac only (xcrun dyld_info, simctl). Dumps default to this folder.
"""
import argparse, collections, json, os, re, struct, subprocess, sys

ARM64, X86_64 = 0x0100000C, 0x01000007


def load_dump(path):
    methods, supers, images = collections.defaultdict(set), {}, {}
    for line in open(path, errors="replace"):
        p = line.rstrip("\n").split("\t")
        if p[0] == "C" and len(p) >= 4:
            supers[p[1]], images[p[1]] = p[2], p[3]
        elif p[0] in "+-" and len(p) >= 3:
            methods[(p[0], p[1])].add(p[2])
    return methods, supers, images


def shim_surface(app):
    """Classes and categories the built shims and host define, from their ObjC metadata."""
    methods, supers, net = collections.defaultdict(set), {}, set()
    files = [os.path.join(app, "Frameworks", f) for f in os.listdir(os.path.join(app, "Frameworks")) if f.startswith("libShack")]
    files.append(os.path.join(app, os.path.basename(app).replace(".app", "")))
    for f in files:
        out = subprocess.run(["xcrun", "dyld_info", "-arch", "arm64", "-objc", f], capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.match(r"\s*@interface (\w+)\s*:\s*(\w+)", line)
            if m:
                supers[m.group(1)] = m.group(2)
                continue
            m = re.search(r"([+-])\[(\w+)(?:\(\w*\))? ([^\]]+)\]", line)
            if m:
                methods[(m.group(1), m.group(2))].add(m.group(3))
                if m.group(3) == "forwardInvocation:":
                    net.add((m.group(1), m.group(2)))
    return methods, supers, net


def slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n, out = struct.unpack(">I", data[4:8])[0], {}
        for i in range(n):
            if magic == 0xCAFEBABE:
                cpu, _, off, size, _ = struct.unpack(">iiIII", data[8 + i * 20:28 + i * 20])
            else:
                cpu, _, off, size, _, _ = struct.unpack(">iiQQII", data[8 + i * 32:40 + i * 32])
            out[cpu] = off
        return out
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return {struct.unpack("<i", data[4:8])[0]: 0}
    return {}


def selrefs(data, off):
    """Selector names from __objc_selrefs, decoding classic pointers, chained fixups and arm64e auth rebases."""
    ncmds = struct.unpack("<I", data[off + 16:off + 20])[0]
    p, base, secs = off + 32, None, {}
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[p:p + 8])
        if cmd == 0x19:   # LC_SEGMENT_64
            seg = data[p + 8:p + 24].rstrip(b"\0").decode()
            vmaddr, _, fileoff = struct.unpack("<QQQ", data[p + 24:p + 48])
            if seg == "__TEXT":
                base = vmaddr
            nsects = struct.unpack("<I", data[p + 64:p + 68])[0]
            for s in range(nsects):
                q = p + 72 + s * 80
                name = data[q:q + 16].rstrip(b"\0").decode()
                addr, sz, soff = struct.unpack("<QQI", data[q + 32:q + 52])
                secs[name] = (addr, sz, soff)
        p += size
    if "__objc_selrefs" not in secs or "__objc_methname" not in secs or base is None:
        return set()
    maddr, msz, moff = secs["__objc_methname"]
    raddr, rsz, roff = secs["__objc_selrefs"]
    out = set()
    for i in range(rsz // 8):
        v = struct.unpack("<Q", data[off + roff + i * 8:off + roff + i * 8 + 8])[0]
        for t in (v, v & 0xFFFFFFFFF, base + (v & 0xFFFFFFFFF), base + (v & 0xFFFFFFFF)):
            if maddr <= t < maddr + msz:
                s = off + moff + (t - maddr)
                out.add(data[s:data.index(b"\0", s)].decode(errors="replace"))
                break
    return out


def own_and_imports(path, arch):
    own, supers, imports = set(), {}, set()
    o = subprocess.run(["xcrun", "dyld_info", "-arch", arch, "-objc", "-imports", path], capture_output=True, text=True).stdout
    for line in o.splitlines():
        m = re.match(r"\s*@interface (\w+)\s*:\s*(\w+)", line)
        if m:
            supers[m.group(1)] = m.group(2)
        m = re.search(r"[+-]\[\w+(?:\(\w*\))? ([^\]]+)\]", line)
        if m:
            own.add(m.group(1))
        m = re.match(r"\s+0x\w+\s+(_OBJC_CLASS_\$_(\w+))(\s+\[weak-import\])?\s+\(from ([^)]+)\)", line)
        if m:
            imports.add((m.group(2), m.group(4), bool(m.group(3))))
    return own, supers, imports


def machos(root):
    if os.path.isfile(root):
        yield root
        return
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p) or os.path.getsize(p) < 16384:
                continue
            with open(p, "rb") as fh:
                if fh.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                    yield p


class World:
    def __init__(self, mac, ios, shim, public, proto, added):
        (self.mm, self.ms, self.mi), (self.im, self.isup, _), (self.sm, self.ssup, self.net) = mac, ios, shim
        self.proto_avail, self.proto_unavail = proto   # from iOS SDK headers: selector -> protocols
        self.added = added                             # selectors the host adds to Metal objects at runtime
        # the system selector -> public macOS declarers index
        self.declarers = collections.defaultdict(set)
        for (kind, cls), sels in self.mm.items():
            img = self.mi.get(cls, "")
            if cls not in public or "/System/Library/Frameworks/" not in img:
                continue
            for s in sels:
                if not s.startswith("_"):
                    self.declarers[s].add((kind, cls))

    def sup(self, c):
        return self.ssup.get(c) or self.isup.get(c)

    def exists(self, c):
        return c in self.ssup or c in self.isup

    def resolves(self, kind, cls, sel):
        c, seen = cls, set()
        while c and c not in seen:
            seen.add(c)
            if sel in self.im.get((kind, c), ()) or sel in self.sm.get((kind, c), ()):
                return True
            c = self.sup(c)
        return kind == "+" and sel in self.im.get(("-", "NSObject"), ())

    def netted(self, kind, cls):
        c, seen = cls, set()
        while c and c not in seen:
            seen.add(c)
            if (kind, c) in self.net:
                return True
            c = self.sup(c)
        return False

    def classify(self, sel):
        """None (not a public macOS API or covered), else (severity, declarers)."""
        decl = self.declarers.get(sel)
        if not decl:
            # protocol API (Metal and friends): the iOS SDK marks the macOS-only declarations API_UNAVAILABLE(ios)
            if sel in self.proto_unavail and sel not in self.proto_avail and sel not in self.added:
                return ("hard", {("p", p) for p in self.proto_unavail[sel]})
            return None
        if any(self.resolves(k, c, sel) for k, c in decl):
            return None
        live = [(k, c) for k, c in decl if self.exists(c)]
        if not live:
            return ("class-missing", decl)
        return ("soft" if any(self.netted(k, c) for k, c in live) else "hard", decl)


MACRO = re.compile(r"\b(?:API_|NS_|MTL_|GC_|CA_|AV_|CI_|__)\w*\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)")


def selectors_of(decl):
    d = decl.strip()
    if d.startswith("@property"):
        attrs = re.match(r"@property\s*\(([^)]*)\)", d)
        a = attrs.group(1) if attrs else ""
        body = MACRO.sub("", d[attrs.end():] if attrs else d[9:])
        names = re.findall(r"[A-Za-z_]\w*", body)
        if not names:
            return []
        name = names[-1]
        g = re.search(r"getter\s*=\s*(\w+)", a)
        out = [g.group(1) if g else name]
        if "readonly" not in a:
            st = re.search(r"setter\s*=\s*(\w+:)", a)
            out.append(st.group(1) if st else "set" + name[0].upper() + name[1:] + ":")
        return out
    if not d[:1] in "+-":
        return []
    body = MACRO.sub("", d[1:])
    while True:   # drop parenthesized types, innermost first
        nb = re.sub(r"\([^()]*\)", " ", body)
        if nb == body:
            break
        body = nb
    kw = re.findall(r"(\w+)\s*:", body)
    if kw:
        return ["".join(k + ":" for k in kw)]
    m = re.search(r"[A-Za-z_]\w*", body)
    return [m.group(0)] if m else []


def protocol_availability(sdk, frameworks):
    """selector -> protocols, split by whether the iOS SDK declaration says API_UNAVAILABLE(ios)."""
    avail, unavail = collections.defaultdict(set), collections.defaultdict(set)
    for fw in frameworks:
        hdr = os.path.join(sdk, "System/Library/Frameworks", fw + ".framework", "Headers")
        if not os.path.isdir(hdr):
            continue
        for f in os.listdir(hdr):
            if not f.endswith(".h"):
                continue
            text = open(os.path.join(hdr, f), errors="replace").read()
            text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
            text = re.sub(r"//[^\n]*", " ", text)
            for m in re.finditer(r"@protocol\s+(\w+)\s*(<[^>]*>)?(?!\s*;)(.*?)@end", text, re.S):
                name, body = m.group(1), m.group(3)
                for decl in body.split(";"):
                    d = " ".join(decl.split())
                    d = re.sub(r"^.*?(?=@property|[+-]\s*\()", "", d)   # drop @optional/@required and leftovers
                    no_ios = re.search(r"API_UNAVAILABLE\([^()]*\bios\b", d) is not None
                    for sel in selectors_of(d):
                        (unavail if no_ios else avail)[sel].add(name)
    return avail, unavail


def metal_added(shackmetal):
    try:
        return set(re.findall(r'addMissing\([^,]+,\s*"([^"]+)"', open(shackmetal).read()))
    except OSError:
        return set()


ENGINES = [("Unity", rb"UnityPlayer|Unity Technologies"), ("Godot 3", rb"OS_OSX"), ("Godot 4", rb"OS_MacOS|DisplayServerMacOS"),
           ("GLFW", rb"NSGL: Failed to locate OpenGL framework"), ("SDL3", rb"SDL3"), ("SDL2", rb"SDL-2\.|SDL_CreateWindow"),
           ("Chowdren", rb"Chowdren"), ("LOVE", rb"love\.graphics"), ("Unreal", rb"FEngineLoop"), ("Solar2D", rb"CoronaCards|Solar2D"),
           ("MonoGame/FNA", rb"FNA3D|MonoGame"), ("Rust/winit", rb"winit::platform_impl"), ("GameMaker", rb"YoYo Games|YoYoGames"), ("The Forge", rb"The-Forge|TheForge|IFileSystem"), ("Ren'Py", rb"renpy"),
           ("RPG Maker/NW.js", rb"nw\.js|node-webkit"), ("Defold", rb"dmengine|Defold")]


def engine_and_gl(root):
    """Engine names seen in the main binaries, and whether the game draws with OpenGL only (no Metal/MoltenVK)."""
    found, gl, metal = [], False, False
    for path in machos(root):
        data = open(path, "rb").read()
        for name, pat in ENGINES:
            if name not in found and re.search(pat, data):
                found.append(name)
        gl |= b"/OpenGL.framework/" in data or b"com.apple.opengl" in data
        metal |= b"_MTLCreateSystemDefaultDevice" in data or b"_MTLCopyAllDevices" in data or "MoltenVK" in os.path.basename(path)
    return found, gl, metal


def c_symbols(root, repo, shims_dir, apis):
    """Strong C imports nothing provides: shackprep's arm64 report, and gaps.py's AArchX classification for x86-only files."""
    sys.path[:0] = [os.path.join(repo, "prep"), os.path.join(repo, "prep", "aarchx")]
    import shackprep, gaps
    sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
    missing = set()
    try:
        for p, r in shackprep.gap_report2(root, sdk, shims_dir).items():
            missing |= {h for h in r["hard"] if not h.startswith("<")}
    except Exception as e:
        print(f"  arm64 C pass failed on {root}: {e}", file=sys.stderr)
    db, host = gaps.load_db(apis), gaps.Host(shims_dir, sdk)
    for path in gaps.x86_machos(root):
        if "arm64" in subprocess.run(["lipo", "-archs", path], capture_output=True, text=True).stdout.split():
            continue
        for sym, lib, weak in gaps.imports(path):
            if lib == "flat-namespace" or lib.startswith("@") or weak:
                continue
            cat, why = gaps.classify(sym, lib, db, host)
            if cat in ("stub", "host-missing"):
                missing.add(f"{lib}/{sym} [x86 {cat}]")
    return missing


def audit(world, game_roots):
    per_game = {}
    for root in game_roots:
        name = os.path.basename(root.rstrip("/"))
        gaps, classes = {}, {}
        for path in machos(root):
            data = open(path, "rb").read()
            sl = slices(data)
            cpu = ARM64 if ARM64 in sl else X86_64 if X86_64 in sl else None
            if cpu is None:
                continue
            arch = "arm64" if cpu == ARM64 else "x86_64"
            sels = selrefs(data, sl[cpu])
            if not sels:
                continue
            own, own_supers, imports = own_and_imports(path, arch)
            for s in sels - own:
                r = world.classify(s)
                if r:
                    gaps[s] = (r[0], sorted(f"{k}{c}" for k, c in r[1])[:4], arch)
            for cls, lib, weak in imports:
                if not weak and not world.exists(cls) and cls in world.ms:
                    classes[cls] = (lib, weak, arch)
        eng, gl, metal = engine_and_gl(root)
        per_game[name] = {"gaps": gaps, "classes": classes, "engine": eng, "gl_only": gl and not metal and "Unity" not in eng}
        print(f"{name}: {sum(1 for g in gaps.values() if g[0] == 'hard')} hard, "
              f"{sum(1 for g in gaps.values() if g[0] == 'soft')} soft, {len(classes)} missing classes", file=sys.stderr)
    return per_game


def self_test():
    """The two parsers that fail silently: header declarations and __objc_selrefs decoding (both pointer formats)."""
    assert selectors_of("- (void)didModifyRange:(NSRange)range API_AVAILABLE(macos(10.11)) API_UNAVAILABLE(ios)") == ["didModifyRange:"]
    assert selectors_of("@property (readonly, getter=isLowPower) BOOL lowPower API_UNAVAILABLE(ios)") == ["isLowPower"]
    assert selectors_of("@property (nonatomic) NSUInteger peerIndex") == ["peerIndex", "setPeerIndex:"]
    assert selectors_of("- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer> b))block") == ["addCompletedHandler:"]
    import tempfile
    src = '#import <Foundation/Foundation.h>\nint main(){ id o=[NSObject new]; [o performSelector:@selector(shackProbe:withArg:) withObject:o withObject:o]; return [o hash]; }\n'
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "t.m"), "w").write(src)
        for arch, target in (("arm64", "arm64-apple-macos13"), ("x86_64", "x86_64-apple-macos10.9")):   # chained vs classic
            out = os.path.join(d, arch)
            subprocess.run(["clang", "-target", target, "-framework", "Foundation", os.path.join(d, "t.m"), "-o", out], check=True)
            data = open(out, "rb").read()
            sl = slices(data)
            got = selrefs(data, sl[ARM64 if arch == "arm64" else X86_64])
            assert {"performSelector:withObject:withObject:", "hash", "shackProbe:withArg:"} <= got, (arch, got)
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    ap.add_argument("--mac", default=os.path.join(here, "mac.tsv"))
    ap.add_argument("--ios", default=os.path.join(here, "ios.tsv"))
    ap.add_argument("--shims", default=os.path.join(repo, "build/Build/Products/Release-iphoneos/MacShack.app"), help="built MacShack.app")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--public", default=os.path.join(here, "mac_public_classes.txt"), help="class names from the macOS SDK headers")
    ap.add_argument("--repo", default=repo)
    ap.add_argument("--apis", default=os.path.join(repo, "vendor/AArchX/runtime/apis/macos/27.0"))
    ap.add_argument("--no-c", action="store_true")
    ap.add_argument("games", nargs="*")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    # the macOS SDK keeps macOS-only declarations and marks them API_UNAVAILABLE(ios); the iOS SDK drops them
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
    proto = protocol_availability(sdk, ["Metal", "MetalKit", "MetalFX", "GameController", "QuartzCore", "AVFoundation", "AVFAudio", "CoreImage", "CoreHaptics"])
    public = set(open(a.public).read().split())
    world = World(load_dump(a.mac), load_dump(a.ios), shim_surface(a.shims), public, proto,
                  metal_added(os.path.join(a.repo, "host", "ShackMetal.m")))
    per_game = audit(world, a.games)
    if not a.no_c:
        for root in a.games:
            per_game[os.path.basename(root.rstrip("/"))]["c_missing"] = sorted(c_symbols(root, a.repo, os.path.join(a.shims, "Frameworks"), a.apis))
    if a.json:
        json.dump(per_game, open(a.json, "w"), indent=1, default=list)
    for sev in ("hard", "soft", "class-missing"):
        tally = collections.Counter()
        where = collections.defaultdict(list)
        for g, r in per_game.items():
            for s, (sv, decl, arch) in r["gaps"].items():
                if sv == sev:
                    tally[(s, tuple(decl))] += 1
                    where[(s, tuple(decl))].append(g)
        print(f"\n== {sev}: {len(tally)} selectors")
        for (s, decl), n in tally.most_common(60):
            print(f"{n:3}  {s:55} {' '.join(decl)[:70]:70}  {', '.join(where[(s, decl)])[:80]}")
    print("\n== engines (GL only = draws with OpenGL and has no Metal/MoltenVK path: needs SHACK_OPENGL=1 on arm64)")
    for g, r in per_game.items():
        print(f"  {g:34} {', '.join(r['engine']) or '?':30} {'GL only' if r['gl_only'] else ''}")
    tally, where = collections.Counter(), collections.defaultdict(list)
    for g, r in per_game.items():
        for c in r.get("c_missing", []):
            tally[c] += 1
            where[c].append(g)
    print(f"\n== C symbols nothing provides: {len(tally)}")
    for c, n in tally.most_common(80):
        print(f"{n:3}  {c:70} {', '.join(where[c])[:70]}")
    tally = collections.Counter()
    for g, r in per_game.items():
        for c in r["classes"]:
            tally[c] += 1
    print(f"\n== classes no side defines: {len(tally)}")
    for c, n in tally.most_common(60):
        print(f"{n:3}  {c}")


if __name__ == "__main__":
    main()
