import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shlex
import ssl
import struct
import subprocess
import tempfile


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True).stdout


def signature_slots(path):
    data = path.read_bytes()
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", data)
    assert magic == 0xFEEDFACF and cpu == 0x100000C and kind == 6
    pos = 32
    for _ in range(count):
        cmd, length = struct.unpack_from("<II", data, pos)
        assert length >= 8 and pos + length <= 32 + size
        if cmd == 0x1D:
            offset, size = struct.unpack_from("<II", data, pos + 8)
            blob = data[offset:offset + size]
            magic, length, count = struct.unpack_from(">III", blob)
            assert magic == 0xFADE0CC0 and length <= len(blob)
            slots = {}
            for i in range(count):
                slot, offset = struct.unpack_from(">II", blob, 12 + i * 8)
                magic, size = struct.unpack_from(">II", blob, offset)
                assert size >= 8 and offset + size <= length
                slots[slot] = blob[offset:offset + size]
            return slots
        pos += length
    raise AssertionError("No LC_CODE_SIGNATURE")


def inspect_crash(path):
    report = json.loads(path.read_text().split("\n", 1)[1])
    print(report["exception"], report["termination"])
    thread = report["threads"][report["faultingThread"]]
    images = report["usedImages"]
    for frame in thread["frames"][:30]:
        image = images[frame["imageIndex"]]
        print(image["name"], hex(frame["imageOffset"]), frame.get("symbol", ""))


def inspect(path):
    data = path.read_bytes()
    slots = signature_slots(path)
    print(f"{path.name}: slots {sorted(slots)}")
    if 5 in slots:
        try:
            ent = plistlib.loads(slots[5][8:])
            print(f"XML entitlements: valid keys={sorted(ent)}")
        except Exception as error:
            print(f"XML entitlements: invalid ({error})")
    if 0x10000 in slots and len(slots[0x10000]) > 8:
        with tempfile.TemporaryDirectory() as temp:
            cms = pathlib.Path(temp) / "signature.der"
            cd = pathlib.Path(temp) / "directory.bin"
            cms.write_bytes(slots[0x10000][8:])
            cd.write_bytes(slots[0])
            result = subprocess.run(["openssl", "cms", "-verify", "-inform", "DER", "-in", str(cms),
                                     "-content", str(cd), "-noverify", "-binary", "-out", "/dev/null"], capture_output=True)
            print(f"CMS: {'valid' if result.returncode == 0 else result.stderr.decode().strip()}")
            certs = pathlib.Path(temp) / "certs.pem"
            subprocess.run(["openssl", "cms", "-cmsout", "-inform", "DER", "-in", str(cms),
                            "-certsout", str(certs), "-out", "/dev/null"], check=True, capture_output=True)
            fingerprints = sorted(hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()[:16] for pem in
                                  re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                                             certs.read_text(), re.DOTALL))
            print(f"CMS certificate fingerprints: {fingerprints}")
    for kind in (0, 0x1000):
        if kind not in slots:
            continue
        cd = slots[kind]
        hash_offset, special, count, limit = (struct.unpack_from(">I", cd, off)[0] for off in (16, 24, 28, 32))
        hash_size, hash_type, page_log = cd[36], cd[37], cd[39]
        digest = {1: hashlib.sha1, 2: hashlib.sha256}[hash_type]
        page = 1 << page_log
        mismatched = [i for i in range(count) if digest(data[i * page:min((i + 1) * page, limit)]).digest() !=
                      cd[hash_offset + i * hash_size:hash_offset + (i + 1) * hash_size]]
        bad_special = [i for i in range(1, special + 1) if
                       (digest(slots[i]).digest() if i in slots else b"\0" * hash_size) !=
                       cd[hash_offset - i * hash_size:hash_offset - (i - 1) * hash_size]]
        print(f"CD {kind:#x}: page_size={page}, code_limit={limit}, code pages={count}, mismatched={mismatched}, special mismatched={bad_special}")


def prepare(output, identity, entitlements):
    output.mkdir(exist_ok=False)
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    source = output / "probe.c"
    source.write_text("int shack_probe(void) { return 42; }\n")
    minimal = {key: entitlements[key] for key in (
        "application-identifier", "com.apple.developer.team-identifier", "get-task-allow")}
    bundle_id = entitlements["application-identifier"].split(".", 1)[1]
    manifest = {}
    for name, ent, force, identifier in (
        ("audit-noent", entitlements, False, "audit-noent"),
        ("audit-full", entitlements, True, "audit-full"),
        ("audit-minimal", minimal, True, "audit-minimal"),
        ("audit-host-noent", entitlements, False, bundle_id),
        ("audit-host-full", entitlements, True, bundle_id),
        ("audit-host-minimal", minimal, True, bundle_id),
        ("audit-host-empty", {}, True, bundle_id),
    ):
        path = output / (name + ".dylib")
        plist = output / (name + ".plist")
        plist.write_bytes(plistlib.dumps(ent))
        run("xcrun", "clang", "-isysroot", sdk, "-target", "arm64-apple-ios26.0",
            "-dynamiclib", "-Wl,-no_adhoc_codesign", "-install_name", "@rpath/" + path.name,
            source, "-o", path)
        options = ["--force-library-entitlements"] if force else []
        run("codesign", "--force", "--sign", identity, "--identifier", identifier, "--timestamp=none",
            "--entitlements", plist, "--generate-entitlement-der", *options, path)
        run("codesign", "--verify", "--strict", path)
        slots = signature_slots(path)
        if force:
            assert plistlib.loads(slots[5][8:]) == ent
            assert struct.unpack_from(">I", slots[7])[0] == 0xFADE7172
            actual = run("codesign", "--display", "--entitlements", "-", "--xml", path)
            assert plistlib.loads(actual) == ent
        else:
            assert 5 not in slots and 7 not in slots
        if identity != "-":
            assert 0x10000 in slots and len(slots[0x10000]) > 8
        manifest[path.name] = {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "entitlements": ent if force else {},
            "signature_slots": sorted(slots),
            "expected_return": 42,
        }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("PASS: default library signing drops entitlements; forced signing preserves XML + DER.")
    print(f"Fixtures: {output}")


def test_zsign():
    root = pathlib.Path(__file__).resolve().parents[2]
    src = root / "vendor/zsign/src"
    with tempfile.TemporaryDirectory(prefix="macshack-zsign-") as temp:
        temp = pathlib.Path(temp)
        prepare(temp / "fixtures", "-", {"application-identifier": "TESTTEAM01.com.example.signprobe",
                                     "com.apple.developer.team-identifier": "TESTTEAM01", "get-task-allow": True})
        binary = temp / "signer"
        flags = shlex.split(run("pkg-config", "--cflags", "--libs", "openssl").decode())
        sources = [root / "host/probe/test_zsign.cpp", *(src / f for f in (
            "archo.cpp", "macho.cpp", "openssl.cpp", "signing.cpp", "common/fs.cpp",
            "common/json.cpp", "common/log.cpp", "common/sha.cpp", "common/util.cpp"))]
        run("xcrun", "clang++", "-std=c++17", f"-I{src}", f"-I{src / 'common'}", *sources, *flags, "-o", binary)
        fixture = temp / "fixtures/audit-host-noent.dylib"
        run(binary, fixture)
        run("codesign", "--verify", "--strict", fixture)
        slots = signature_slots(fixture)
        assert 5 not in slots and 7 not in slots
        assert slots[0][39] == 14 and slots[0][37] == 2 and 0x1000 not in slots
        print("PASS: patched ZSign emitted a verifiable SHA-256-only iOS library signature without entitlements.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-app", type=pathlib.Path)
    parser.add_argument("--test-zsign", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--inspect", type=pathlib.Path)
    parser.add_argument("--crash-report", type=pathlib.Path)
    parser.add_argument("--expect-no-entitlements", action="store_true")
    args = parser.parse_args()
    if args.test_zsign:
        test_zsign()
        return
    if args.crash_report:
        inspect_crash(args.crash_report)
        return
    if args.inspect:
        inspect(args.inspect)
        if args.expect_no_entitlements:
            slots = signature_slots(args.inspect)
            assert 5 not in slots and 7 not in slots, "Library signature contains unexpected entitlements"
            assert slots[0][39] == 14, "iOS requires 16 KB code-signing pages"
            assert slots[0][37] == 2 and 0x1000 not in slots, "Expected a single SHA-256 CodeDirectory"
        return
    identity = "-"
    entitlements = {
        "application-identifier": "TESTTEAM01.com.example.signprobe",
        "com.apple.developer.team-identifier": "TESTTEAM01",
        "get-task-allow": True,
    }
    if args.host_app:
        run("codesign", "--verify", args.host_app)
        entitlements = plistlib.loads(run("codesign", "--display", "--entitlements", "-", "--xml", args.host_app))
        details = subprocess.run(["codesign", "--display", "--verbose=2", str(args.host_app)],
                                 check=True, capture_output=True).stderr.decode()
        identity = next(line.removeprefix("Authority=") for line in details.splitlines() if line.startswith("Authority="))
        if not identity.startswith("Apple Development:") or entitlements.get("get-task-allow") is not True:
            parser.error("A development-signed, get-task-allow host is required")
    if args.output:
        prepare(args.output, identity, entitlements)
    else:
        with tempfile.TemporaryDirectory(prefix="macshack-signing-") as temp:
            prepare(pathlib.Path(temp) / "fixtures", identity, entitlements)


if __name__ == "__main__":
    main()
