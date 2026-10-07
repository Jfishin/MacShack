"""Run Mac installer transaction checks using native prep and an unsigned fake signer."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="macshack-installer-") as directory:
    temp = pathlib.Path(directory)
    source = temp / "main.c"
    source.write_text("int main(void) { return 42; }\n")
    fixture = temp / "fixture"
    subprocess.run(["xcrun", "clang", "-arch", "arm64", "-Wl,-headerpad,0x4000", str(source), "-o", str(fixture)], check=True)
    rpathed = temp / "fixture-rpath"   # a framework binary that looks beside itself, as CoronaCards does
    subprocess.run(["xcrun", "clang", "-arch", "arm64", "-Wl,-headerpad,0x4000", "-Wl,-rpath,@loader_path/Frameworks", str(source), "-o", str(rpathed)], check=True)
    intel = temp / "fixture-x86_64"
    subprocess.run(["xcrun", "clang", "-arch", "x86_64", str(source), "-o", str(intel)], check=True)
    # A universal static library, as in Firebase's Plugins/<Name>.framework/<Name> (Coromon): fat, arm64 entry, `ar` slice.
    archives = []
    for arch in ("arm64", "x86_64"):
        obj = temp / f"static-{arch}.o"
        subprocess.run(["xcrun", "clang", "-arch", arch, "-c", str(source), "-o", str(obj)], check=True)
        lib = temp / f"static-{arch}.a"
        subprocess.run(["xcrun", "libtool", "-static", "-o", str(lib), str(obj)], check=True)
        archives.append(str(lib))
    universal = temp / "static-universal"
    subprocess.run(["xcrun", "lipo", "-create", *archives, "-output", str(universal)], check=True)
    binary = temp / "test-installer"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-DSHACK_INSTALLER_TEST", "-Wno-deprecated-declarations",
                    str(root / "host/ShackInstaller.m"), str(root / "host/ShackPrep.m"),
                    str(root / "host/probe/test_installer.m"), "-framework", "Foundation", "-o", str(binary)], check=True)
    # An i386-only program (Feral's Batman is one): CLT's ld no longer links i386, so the m32 gate's ret42 stands in.
    i386 = root / "vendor/AArchX/tests/m32/bin/ret42"
    extra = [str(i386)] if i386.exists() else []
    subprocess.run([str(binary), str(fixture), str(intel), str(universal), str(rpathed), *extra], check=True,
                   env={**os.environ, "SHACK_INSTALLER_TEST_ROOT": str(temp / "container"),
                        "SHACK_INSTALLER_TEST_FRAMEWORKS": str(temp / "Frameworks")})
