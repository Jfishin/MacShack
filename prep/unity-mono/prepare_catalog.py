#!/usr/bin/env python3
"""Prepare locally built, revision-matched Mono runtimes for the host's signed catalog."""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import shackprep


def prepare(source, destination, identity):
    if destination.exists():
        shutil.rmtree(destination)
    if not source.is_dir():
        return
    for entry in sorted(source.iterdir()):
        if not entry.is_dir() or not re.fullmatch(r"[0-9a-f]{8}", entry.name):
            continue
        runtime = entry / "libmonobdwgc-2.0.dylib"
        data = runtime.read_bytes()
        if b"explicit/" + entry.name.encode() not in data or b"dual-mapped JIT pool" not in data:
            raise RuntimeError(f"{entry.name}: missing matching revision or dual-map marker")
        with tempfile.TemporaryDirectory() as work:
            contents = pathlib.Path(work) / "Contents"
            frameworks = contents / "Frameworks"
            frameworks.mkdir(parents=True)
            binary = frameworks / runtime.name
            shutil.copyfile(runtime, binary)
            shackprep.thin_arm64(str(binary))
            shackprep.set_ios_platform(str(binary))
            shackprep.link_libsystem(str(binary))
            shackprep.rewrite_links(str(binary), shackprep.LINK_MAP, str(contents / "MacOS"))
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(binary)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
            target = destination / entry.name
            target.mkdir(parents=True)
            shutil.copyfile(binary, target / runtime.name)
            print(f"Embedded dual-mapped Mono {entry.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("identity")
    args = parser.parse_args()
    prepare(args.source, args.destination, args.identity)
