#!/usr/bin/env python3
"""Resumable per-file copy of a directory into the MacShack app container on a device.

Usage: devsync.py <device-id> <local-dir> <remote-dir-under-Documents> [--dry-run] [--bulk] [--skip <file name>]...
Compares sizes with `devicectl device info files`, copies missing/mismatched files one
at a time with retries. --bulk first copies each folder of many small files in one call
(one devicectl call costs ~1-2 s, so 15k small files one by one take hours), then runs
the per-file pass to fill whatever is still missing. --skip leaves out files of that name (Cyberpunk 2077's non-English
voice packs). stdlib only.
"""
import json, os, re, subprocess, sys, tempfile, time

SKIP = set()   # file names --skip leaves out

# The app's bundle id: MACSHACK_BUNDLE_ID, else Signing.xcconfig's (ponytail: Signing.local.xcconfig not read; use the env).
BUNDLE_ID = os.environ.get("MACSHACK_BUNDLE_ID") or re.search(r"^MACSHACK_BUNDLE_ID\s*=\s*(\S+)", open(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Signing.xcconfig")).read(), re.M).group(1)

def remote_listing(device, subdir):
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f: out = f.name
    subprocess.run(["xcrun", "devicectl", "device", "info", "files", "--device", device,
                    "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID,
                    "--subdirectory", subdir, "--json-output", out],
                   check=False, capture_output=True, text=True)
    sizes = {}
    try:
        data = json.load(open(out))
        base = subdir.rstrip("/").split("/")[-1]          # listing paths are relative to the parent of subdir
        for e in data.get("result", {}).get("files", []):
            if e.get("resources", {}).get("isDirectory"): continue
            rel = e["relativePath"]
            if rel.startswith(base + "/"): rel = rel[len(base) + 1:]
            sizes[rel] = int(e.get("metadata", {}).get("size", -1))
    except (json.JSONDecodeError, KeyError, FileNotFoundError):
        pass
    finally:
        if os.path.exists(out): os.unlink(out)
    return sizes

def local_files(root):
    for d, _, fs in os.walk(root):
        for fn in fs:
            p = os.path.join(d, fn)
            # "._x" AppleDouble files (non-Mac volumes such as exFAT store metadata in them) and .DS_Store are not game data
            if not os.path.islink(p) and not fn.startswith("._") and fn != ".DS_Store" and fn not in SKIP: yield os.path.relpath(p, root), os.path.getsize(p)

def copy_one(device, src, dest_dir, tries=4):
    for i in range(tries):
        r = subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device,
                            "--source", src, "--destination", dest_dir,
                            "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID],
                           capture_output=True, text=True)
        if r.returncode == 0: return True
        print(f"   retry {i+1}: {r.stderr.strip().splitlines()[0] if r.stderr.strip() else r.returncode}", flush=True)
        time.sleep(15)
    return False

BULK_MAX = 1_500_000_000   # bytes per directory call; whole-tree copies of tens of GB drop mid-way

def bulk_dirs(root):
    """Directories to copy whole: the largest subtrees under BULK_MAX with at least 20 files."""
    out = []
    def visit(d):
        files = [os.path.join(dp, f) for dp, _, fs in os.walk(d) for f in fs
                 if not os.path.islink(os.path.join(dp, f)) and not f.startswith("._") and f != ".DS_Store"]
        if d != root and len(files) >= 20 and sum(os.path.getsize(f) for f in files) <= BULK_MAX: out.append(d); return
        for e in sorted(os.listdir(d)):
            if os.path.isdir(os.path.join(d, e)) and not os.path.islink(os.path.join(d, e)): visit(os.path.join(d, e))
    visit(root)
    return out

def main(device, local, remote, dry, bulk=False):
    remote = remote.rstrip("/")
    if bulk and not dry:
        dirs = bulk_dirs(local)
        for n, d in enumerate(dirs, 1):
            rel = os.path.relpath(d, local)
            print(f"[bulk {n}/{len(dirs)}] {rel}", flush=True)
            copy_one(device, d, f"{remote}/{rel}")   # misses are caught by the per-file pass below
    have = remote_listing(device, remote)
    todo = [(rel, sz) for rel, sz in local_files(local) if have.get(rel) != sz]
    total = sum(sz for _, sz in todo)
    print(f"{len(todo)} files to copy, {total/1e9:.2f} GB; {len(have)} remote entries seen", flush=True)
    if dry:
        for rel, sz in sorted(todo, key=lambda t: -t[1])[:30]: print(f"  {sz/1e9:7.2f} GB  {rel} (remote {have.get(rel)})")
        return 0
    failed = []
    for n, (rel, sz) in enumerate(sorted(todo, key=lambda t: t[1]), 1):   # small files first
        dest = f"{remote}/{rel}"   # devicectl copies TO this exact path (not into it)
        print(f"[{n}/{len(todo)}] {sz/1e9:.2f} GB {rel}", flush=True)
        if not copy_one(device, os.path.join(local, rel), dest): failed.append(rel)
    print("failed:", failed if failed else "none")
    return 1 if failed else 0

if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if x != "--dry-run"]
    while "--skip" in a: i = a.index("--skip"); SKIP.add(a[i + 1]); del a[i:i + 2]
    a = [x for x in a if x != "--bulk"]
    sys.exit(main(a[0], a[1], a[2], "--dry-run" in sys.argv, "--bulk" in sys.argv))
