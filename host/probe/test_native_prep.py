#!/usr/bin/env python3
"""Mac-native unsigned prep checks against shackprep.py. No game source or signing key needed.
Run: python3 host/probe/test_native_prep.py [--binary /path/to/real/game/binary]
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'prep'))
import shackprep

REAL_BINARY = None


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT)


def commands(data):
    out = []
    off = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, off)
        out.append((cmd, data[off:off + size]))
        off += size
    return out


def semantic(data):
    """Load commands and ordinals, ignoring harmless padding and build-command placement."""
    result = []
    build = []
    for cmd, body in commands(data):
        if cmd == 0x32:
            build.append((cmd, struct.unpack_from('<III', body, 8)))
        elif cmd & 0x7fffffff in (0xc, 0xd, 0x18, 0x1f, 0x20, 0x23, 0x1c):
            start = struct.unpack_from('<I', body, 8)[0]
            name = body[start:].split(b'\0')[0]
            meta = body[12:24] if cmd != 0x8000001c else b''
            result.append((cmd, meta, name))
        elif cmd == 0x19 and body[8:24].rstrip(b'\0') == b'__LINKEDIT':
            # Apple tools replace the ad-hoc signature, changing the trailing segment size.
            normalized = bytearray(body[8:])
            struct.pack_into('<Q', normalized, 24, 0)  # vmsize
            struct.pack_into('<Q', normalized, 40, 0)  # filesize
            result.append((cmd, bytes(normalized)))
        elif cmd != 0x1d:  # vtool/install_name_tool invalidate signatures; signing is a separate step.
            result.append((cmd, body[8:]))
    return result + build


class NativePrepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = pathlib.Path(tempfile.mkdtemp(prefix='macshack-native-prep-'))
        cls.cli = cls.root / 'shackprep_cli'
        run('clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', ROOT / 'host/ShackPrep.m',
            ROOT / 'host/probe/shackprep_cli.m', '-framework', 'Foundation', '-o', cls.cli)
        cls.sdk = run('xcrun', '--sdk', 'macosx', '--show-sdk-path').decode().strip()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(dir=self.root))
        self.exe_dir = self.tmp / 'Game.app/Contents/MacOS'
        self.exe_dir.mkdir(parents=True)
        self.exe = self.exe_dir / 'Game'
        self.out = self.tmp / 'native'
        self.compile(self.exe)

    def compile(self, path, *args):
        run('clang', '-isysroot', self.sdk, '-target', 'arm64-apple-macos13.0',
            ROOT / 'host/probe/hello.c', '-Wl,-headerpad,0x1000', *args, '-o', path)

    def prep(self, source=None, main=True, output=None):
        return subprocess.run([str(self.cli), str(source or self.exe), str(output or self.out),
                               str(self.exe_dir), str(int(main))], capture_output=True)

    def reference(self, source, main):
        reference = source.with_name(source.name + '.reference')
        shutil.copyfile(source, reference)
        shackprep.thin_arm64(str(reference))
        shackprep.set_ios_platform(str(reference))
        if main:
            shackprep.exec_to_dylib(str(reference))
        shackprep.link_libsystem(str(reference))
        shackprep.rewrite_links(str(reference), shackprep.LINK_MAP, str(self.exe_dir))
        return reference.read_bytes()

    def assertEquivalent(self, source=None, main=True):
        source = source or self.exe
        original = source.read_bytes()
        result = self.prep(source, main)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        actual = self.out.read_bytes()
        expected = self.reference(source, main)
        self.assertEqual(semantic(actual), semantic(expected))
        self.assertEqual(struct.unpack_from('<IiiI', actual), struct.unpack_from('<IiiI', expected))
        self.assertEqual(struct.unpack_from('<I', actual, 24), struct.unpack_from('<I', expected, 24))
        self.assertEqual(source.read_bytes(), original, 'source must remain unchanged')
        return actual

    def test_executable_and_shims_match_python(self):
        self.compile(self.exe, '-framework', 'Cocoa', '-framework', 'AppKit', '-framework', 'Foundation',
                     '-framework', 'CoreGraphics', '-framework', 'Metal', '-framework', 'AudioToolbox',
                     '-framework', 'AudioUnit', '-framework', 'CoreAudio', '-framework', 'OpenGL',
                     '-framework', 'AVFoundation', '-framework', 'Security', '-framework', 'GLUT',
                     '-Wl,-rpath,@executable_path', '-Wl,-rpath,@executable_path/../Frameworks')
        self.assertNotIn(b'GLUT.framework', self.assertEquivalent())   # GameMaker's runner; iOS has no GLUT

    def test_dylib_relative_links_and_rpaths_match_python(self):
        lib = self.exe_dir.parent / 'Frameworks/lib.dylib'
        lib.parent.mkdir()
        self.compile(lib, '-dynamiclib', '-install_name', '@executable_path/../Frameworks/lib.dylib',
                     '-Wl,-rpath,@executable_path', '-Wl,-rpath,@executable_path/../Frameworks')
        self.assertEquivalent(lib, False)
        self.compile(self.exe, lib)
        self.assertEquivalent()

    def test_fat32_and_fat64_thin_without_payload_changes(self):
        thin = self.exe.read_bytes()
        for wide in (False, True):
            offset = 0x4000
            header = struct.pack('>II', 0xcafebabf if wide else 0xcafebabe, 1)
            arch = struct.pack('>IIQQII', 0x100000c, 0, offset, len(thin), 14, 0) if wide else struct.pack('>IIIII', 0x100000c, 0, offset, len(thin), 14)
            self.exe.write_bytes((header + arch).ljust(offset, b'\0') + thin)
            self.assertEqual(self.prep().returncode, 0)
            actual = self.out.read_bytes()
            after = max(32 + struct.unpack_from('<I', x, 20)[0] for x in (thin, actual))
            self.assertEqual(actual[after:], thin[after:])
            self.assertTrue(json.loads(run(self.cli, '--inspect', self.exe))['arm64'])

    def test_fat_real_universal_matches_python(self):
        intel = self.tmp / 'intel'
        run('clang', '-isysroot', self.sdk, '-target', 'x86_64-apple-macos13.0', ROOT / 'host/probe/hello.c', '-o', intel)
        universal = self.exe_dir / 'Universal'
        run('lipo', '-create', self.exe, intel, '-output', universal)
        self.assertEquivalent(universal)

    def assertRejected(self, data, message=None):
        self.exe.write_bytes(data)
        self.out.write_bytes(b'previous output')
        result = self.prep()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.out.read_bytes(), b'previous output')
        self.assertEqual(self.exe.read_bytes(), data)
        if message:
            self.assertIn(message, result.stderr.decode())

    def test_rejects_malformed_and_encrypted_atomically(self):
        good = self.exe.read_bytes()
        for truncated in (b'', b'\xcf\xfa\xed\xfe', good[:31], good[:40]):
            self.assertRejected(truncated)
        for offset, val in ((16, 0xffffffff), (20, 0xffffffff), (36, 0), (36, 7), (36, 0xfffffff8), (8, 2)):
            bad = bytearray(good); struct.pack_into('<I', bad, offset, val)
            self.assertRejected(bad)
        # Replace the build version command with a valid encryption command, cryptid = 2.
        off = 32
        for cmd, body in commands(good):
            if cmd == 0x32:
                bad = bytearray(good)
                struct.pack_into('<IIIIII', bad, off, 0x2c, 24, 0, 0, 2, 0)
                # Original includes linker tools; use command's existing size to retain table bounds.
                struct.pack_into('<I', bad, off + 4, len(body))
                self.assertRejected(bad, 'Encrypted')
                break
            off += len(body)
        # Universal entry must not point back into its own architecture table.
        self.assertRejected(struct.pack('>IIIIIII', 0xcafebabe, 1, 0x100000c, 0, 8, 32, 0) + good)
        # Ensure a load command path cannot read beyond its own command.
        off = 32
        for cmd, body in commands(good):
            if cmd == 0xc:
                bad = bytearray(good); struct.pack_into('<I', bad, off + 8, len(body))
                self.assertRejected(bad, 'string offset')
                bad = bytearray(good); bad[off + 24:off + len(body)] = b'x' * (len(body) - 24)
                self.assertRejected(bad, 'Unterminated')
                break
            off += len(body)

    def test_rejects_header_growth_into_code(self):
        deep = self.exe_dir
        for _ in range(40):
            deep = deep / 'd'
        deep.mkdir(parents=True)
        source = deep / 'lib'
        self.compile(source, '-dynamiclib', '-Wl,-rpath,@executable_path')
        # Relative path growth fits the compiler's headerpad until it contains occupied bytes.
        self.assertEqual(self.prep(source, False).returncode, 0)
        data = bytearray(source.read_bytes())
        end = 32 + struct.unpack_from('<I', data, 20)[0]
        data[end:end + 128] = b'X' * 128
        source.write_bytes(data)
        result = self.prep(source, False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nonzero data', result.stderr.decode())

    def test_main_requires_a_preserved_entry(self):
        self.compile(self.exe, '-dynamiclib')
        self.assertRejected(self.exe.read_bytes(), 'LC_MAIN')

    def test_dependency_free_dylib_gets_system_shim(self):
        self.compile(self.exe, '-dynamiclib', '-install_name', 'a' * 140)
        data = bytearray(self.exe.read_bytes())
        # Remove loads without changing any payload offsets; this file has no bindings exercised.
        cmds = [body for cmd, body in commands(data) if cmd != 0xc]
        old_size = struct.unpack_from('<I', data, 20)[0]
        blob = b''.join(cmds)
        data[32:32 + old_size] = blob.ljust(old_size, b'\0')
        struct.pack_into('<II', data, 16, len(cmds), len(blob))
        self.exe.write_bytes(data)
        actual = self.assertEquivalent(main=False)
        self.assertIn(b'@rpath/libShackSystem.dylib\0', actual)

    def test_mono_marker(self):
        self.exe.write_bytes(b'padding explicit/43035fcf more')
        self.assertEqual(json.loads(run(self.cli, '--inspect', self.exe))['monoRevision'], '43035fcf')

    def test_redengine_pool_reservations_quartered(self):
        # Cyberpunk 2077's two reservation helpers (ShackPrep.m PatchREDPoolReservations), as words in a test program.
        body = [0x8B080029, 0xD1000529, 0xCB0803E8, 0x8A080133, 0xD2800000, 0xAA1303E1, 0x52800062, 0x52820043,
                0x12800004, 0xD2800005]
        h1 = [0xA9BE4FF4, 0xA9017BFD, 0x910043FD, 0x2A0203E8] + body
        h2 = [0x6B02009F, 0x540002C1, 0xA9BE4FF4, 0xA9017BFD, 0x910043FD, 0x2A0403E8] + body   # cmp w4, w2; b.ne; H2
        asm = self.tmp / 'red.s'
        asm.write_text('.text\n.p2align 2\n' + ''.join(f'.long {w:#x}\n' for w in h1 + [0xD65F03C0] + h2))
        self.compile(self.exe, asm)
        source = self.exe.read_bytes()
        p1 = source.index(struct.pack('<14I', *h1)); p2 = source.index(struct.pack('<14I', *h2[2:]))
        result = self.prep()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        out = self.out.read_bytes()
        word = lambda at: struct.unpack_from('<I', out, at)[0]
        branch = lambda frm, to: 0x14000000 | (((to - frm) >> 2) & 0x3FFFFFF)
        self.assertEqual(word(p2), branch(p2, p1))                   # H2 -> H1
        self.assertEqual(word(p1 + 28), branch(p1 + 28, p2 + 4))     # H1's rounding -> the clamp
        cave = [word(p2 + 4 + 4 * i) for i in range(6)]
        self.assertEqual(cave[:2] + cave[3:5], [0x8A080133, 0xD360FE69, 0xD342FE73, 0x8A080273])
        self.assertEqual(cave[2], 0xB4000009 | ((((p1 + 32 - (p2 + 12)) >> 2) & 0x7FFFF) << 5))   # cbz x9 -> back
        self.assertEqual(cave[5], branch(p2 + 24, p1 + 32))
        # Already patched: nothing more changes.
        again = self.tmp / 'again'
        self.assertEqual(self.prep(self.out, output=again).returncode, 0)
        self.assertEqual(again.read_bytes()[p1:p2 + 56], out[p1:p2 + 56])

    def test_real_binary_when_requested(self):
        if not REAL_BINARY:
            self.skipTest('use --binary for a shipped game binary')
        source = pathlib.Path(REAL_BINARY)
        self.exe.write_bytes(source.read_bytes())
        thin = self.tmp / 'thin'
        shutil.copyfile(source, thin)
        shackprep.thin_arm64(str(thin))
        self.assertEquivalent(main=struct.unpack_from('<I', thin.read_bytes(), 12)[0] == 2)
        print('real source SHA-256:', hashlib.sha256(source.read_bytes()).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--binary')
    args, rest = parser.parse_known_args()
    REAL_BINARY = args.binary
    unittest.main(argv=[sys.argv[0]] + rest)
