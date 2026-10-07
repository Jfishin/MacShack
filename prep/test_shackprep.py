import os, subprocess, tempfile, unittest, shutil
import shackprep
from unittest.mock import patch

MACSDK = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
HELLO_SRC = os.path.join(os.path.dirname(__file__), "..", "host", "probe", "hello.c")

def otool_l(p): return subprocess.check_output(["otool", "-l", p], text=True)
def otool_h(p): return subprocess.check_output(["otool", "-h", p], text=True)

class PrepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.app = os.path.join(self.tmp, "Hello.app")
        os.makedirs(os.path.join(self.app, "Contents", "MacOS"))
        self.exe = os.path.join(self.app, "Contents", "MacOS", "Hello")
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "Foundation", HELLO_SRC, "-o", self.exe])
        with open(os.path.join(self.app, "Contents", "Info.plist"), "w") as f:
            f.write('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Hello</string></dict></plist>')

    def tearDown(self): shutil.rmtree(self.tmp)

    def test_set_ios_platform(self):
        shackprep.set_ios_platform(self.exe)
        self.assertIn("platform 2", otool_l(self.exe))       # PLATFORM_IOS

    def test_exec_to_dylib(self):
        shackprep.exec_to_dylib(self.exe)
        h = otool_h(self.exe).split("\n")[-2].split()
        self.assertEqual(h[4], "6")                          # MH_DYLIB
        l = otool_l(self.exe)
        self.assertIn("LC_ID_DYLIB", l)
        self.assertNotIn("LC_LOAD_DYLINKER", l)
        self.assertIn("vmsize 0x0000000000004000", l)        # shrunk __PAGEZERO
        self.assertIn("LC_MAIN", l)                          # entry point preserved

    def test_rewrite_links_strips_versions_and_maps_shims(self):
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "Cocoa", "-framework", "Foundation", "-framework", "CoreGraphics",
                               "-framework", "Metal", "-framework", "CoreAudio", HELLO_SRC, "-o", self.exe])
        changed = shackprep.rewrite_links(self.exe, shackprep.LINK_MAP)
        l = otool_l(self.exe)
        self.assertIn("@rpath/libShackAppKit.dylib", l)
        self.assertNotIn("Versions/", l)
        self.assertIn("@rpath/libShackCV.dylib", l)   # Metal -> CV shim (re-exports Metal, adds the device observer)
        self.assertNotIn("/System/Library/Frameworks/Metal.framework/Metal", l)
        self.assertIn("@rpath/libShackCG.dylib", l)
        self.assertIn("@rpath/libShackCoreAudio.dylib", l)
        self.assertIn("@rpath/./libShackAppKit.dylib", l)   # Foundation -> AppKit shim (NSAppleEventManager)
        self.assertIn("/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa", changed)

    def test_rewrite_links_maps_unity_frameworks_and_libsystem(self):
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "OpenGL", "-framework", "Security",
                               "-framework", "AVFoundation", HELLO_SRC, "-o", self.exe])
        shackprep.rewrite_links(self.exe, shackprep.LINK_MAP)
        libs = shackprep.linked_libs(self.exe)
        self.assertIn("@rpath/libShackOpenGL.dylib", libs)
        self.assertIn("@rpath/libShackSecurity.dylib", libs)
        self.assertIn("@rpath/libShackAVFoundation.dylib", libs)
        self.assertIn("@rpath/libShackSystem.dylib", libs)
        self.assertFalse(any("libShackAppKit" in l for l in libs))   # OpenGL no longer a placeholder on AppKit

    def test_rewrite_links_dedups_shared_shim(self):
        # Cocoa and AppKit both map to one shim; dyld rejects a binary that links the same path twice.
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "Cocoa", "-framework", "AppKit",
                               HELLO_SRC, "-o", self.exe])
        shackprep.rewrite_links(self.exe, {"Cocoa": "@rpath/libShackAppKit.dylib",
                                           "AppKit": "@rpath/libShackAppKit.dylib"})
        libs = shackprep.linked_libs(self.exe)
        self.assertEqual(len(libs), len(set(libs)))
        self.assertIn("@rpath/libShackAppKit.dylib", libs)
        self.assertIn("@rpath/./libShackAppKit.dylib", libs)

    def test_rewrite_links_rejects_unmapped_macos_only(self):
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "Cocoa", HELLO_SRC, "-o", self.exe])
        with self.assertRaises(shackprep.PrepError) as cm:
            shackprep.rewrite_links(self.exe, {})
        self.assertIn("Cocoa", str(cm.exception))

    def test_prep_bundle_end_to_end(self):
        out = shackprep.prep_bundle(self.app, os.path.join(self.tmp, "Out.app"), link_map={})
        exe = os.path.join(out, "Contents", "MacOS", "Hello")
        self.assertIn("platform 2", otool_l(exe))
        self.assertIn("LC_ID_DYLIB", otool_l(exe))

    def test_rewrite_links_makes_executable_path_loader_relative(self):
        fw = os.path.join(self.app, "Contents", "Frameworks"); os.makedirs(fw)
        lib = os.path.join(fw, "Lib.dylib")
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", "-dynamiclib",
                               "-install_name", "@executable_path/../Frameworks/Lib.dylib", HELLO_SRC, "-o", lib])
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", lib, HELLO_SRC, "-o", self.exe])
        shackprep.rewrite_links(self.exe, {}, os.path.dirname(self.exe))
        self.assertIn("@loader_path/../Frameworks/Lib.dylib", shackprep.linked_libs(self.exe))

    BURST = "/Applications/Hollow Knight Silksong/Hollow Knight Silksong.app/Contents/PlugIns/lib_burst_generated.bundle"

    @unittest.skipUnless(os.path.exists(BURST), "needs Silksong's Burst bundle (ld refuses to build a dylib without libSystem)")
    def test_link_libsystem_on_dylib_that_links_nothing(self):
        lib = os.path.join(self.tmp, "burst.bundle")
        subprocess.check_call(["lipo", "-thin", "arm64", self.BURST, "-output", lib])
        shackprep.set_ios_platform(lib)
        self.assertEqual(shackprep.linked_libs(lib)[1:], [])
        self.assertTrue(shackprep.link_libsystem(lib))
        self.assertIn("/usr/lib/libSystem.B.dylib", shackprep.linked_libs(lib))
        self.assertFalse(shackprep.link_libsystem(lib))   # idempotent
        subprocess.check_call(["xcrun", "dyld_info", "-fixups", lib], stdout=subprocess.DEVNULL)   # iOS validation passes

    def test_prep_bundle_binaries_only(self):
        with open(os.path.join(self.app, "Contents", "Big.pak"), "w") as f: f.write("39 GB of data")
        out = shackprep.prep_bundle(self.app, os.path.join(self.tmp, "Out.app"), link_map={}, binaries_only=True)
        files = sorted(os.path.relpath(os.path.join(r, f), out) for r, _, fs in os.walk(out) for f in fs)
        self.assertEqual(files, ["Contents/Info.plist", "Contents/MacOS/Hello"])
        self.assertIn("LC_ID_DYLIB", otool_l(os.path.join(out, "Contents", "MacOS", "Hello")))

    def test_embed_copies_machos_and_plist(self):
        out = shackprep.prep_bundle(self.app, os.path.join(self.tmp, "Out.app"), link_map={})
        with open(os.path.join(out, "Contents", "Resources.txt"), "w") as f: f.write("data stays in Documents")
        dest = shackprep.embed(out, os.path.join(self.tmp, "Guests"))
        self.assertEqual(dest, os.path.join(self.tmp, "Guests", "Out"))
        self.assertTrue(shackprep.is_macho(os.path.join(dest, "Contents", "MacOS", "Hello")))
        files = sorted(os.path.relpath(os.path.join(r, f), dest) for r, _, fs in os.walk(dest) for f in fs)
        self.assertEqual(files, ["Contents/Info.plist", "Contents/MacOS/Hello"])

    def test_gap_report_finds_cocoa_classes_and_ignores_foundation(self):
        subprocess.run(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0",
                               "-framework", "Cocoa", "-x", "objective-c", "-", "-o", self.exe],
                              input=b'#import <Cocoa/Cocoa.h>\nint main(){ [NSApplication sharedApplication]; [NSString new]; return CGDisplayBounds(CGMainDisplayID()).size.width > 0; }', check=True)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        gaps = shackprep.gap_report(self.app, sdk, [])
        missing = gaps[self.exe]
        self.assertIn("_OBJC_CLASS_$_NSApplication", missing)
        self.assertIn("_CGDisplayBounds", missing)
        self.assertNotIn("_OBJC_CLASS_$_NSString", missing)
        self.assertNotIn("_objc_msgSend", missing)

    def test_bind_targets_reads_only_arm64_of_fat(self):
        # Bundled dylibs ship x86_64+arm64; x86_64-only binds (select$1050) must not count as gaps.
        src = os.path.join(self.tmp, "sel.c")   # clang takes no stdin with two -arch
        with open(src, "w") as f: f.write("#include <sys/select.h>\nint main(){return select(0,0,0,0,0);}\n")
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-arch", "x86_64", "-arch", "arm64",
                               "-mmacosx-version-min=11.0", src, "-o", self.exe])
        libsys = shackprep.bind_targets(self.exe)["libSystem"]
        self.assertIn("_select", libsys)
        self.assertNotIn("_select$1050", libsys)

    def test_bind_targets_handles_addends(self):
        sample = """\
        segment         section          address             type   target
        __DATA_CONST    __got            0x100004010           bind  libSystem/_printf
        __DATA_CONST    __la_symbol_ptr  0x100004020      lazy-bind  libSystem/_malloc
        __DATA_CONST    __got            0x100004000           bind  <flat-namespace>/_some_weak_symbol [weak-import]
        __DATA_CONST    __const          0x100004070           bind  libc++/__ZTVN10__cxxabiv121__vmi_class_type_infoE + 0x10
        __DATA_CONST    __const          0x100004098           bind  libc++/__ZTVN10__cxxabiv117__class_type_infoE + 0x10 [weak-import]
"""
        out = shackprep.parse_fixups(sample)
        self.assertEqual(out["libSystem"], {"_printf": False, "_malloc": False})
        self.assertEqual(out["<flat-namespace>"], {"_some_weak_symbol": True})
        self.assertEqual(out["libc++"]["__ZTVN10__cxxabiv121__vmi_class_type_infoE"], False)
        self.assertEqual(out["libc++"]["__ZTVN10__cxxabiv117__class_type_infoE"], True)

    def test_gaps2_is_library_aware(self):
        src = (b'#import <Cocoa/Cocoa.h>\nint main(){ [NSApplication sharedApplication]; '
               b'NSLog(@"%@", NSFontAttributeName); return CGDisplayBounds(CGMainDisplayID()).size.width > 0; }')
        subprocess.run(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", "-framework", "Cocoa",
                        "-x", "objective-c", "-", "-o", self.exe], input=src, check=True)
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        shackprep.rewrite_links(self.exe, {"Cocoa": "@rpath/libShackAppKit.dylib", "AppKit": "@rpath/libShackAppKit.dylib"})
        # no shim dir: everything AppKit-bound is hard unless a re-export covers it
        r = shackprep.gap_report2(self.app, sdk, shim_dir=None)[self.exe]
        self.assertIn("AppKit/_OBJC_CLASS_$_NSApplication", r["hard"])
        self.assertNotIn("AppKit/_NSFontAttributeName", r["hard"])          # UIKit re-export covers it
        self.assertIn("CoreGraphics/_CGDisplayBounds", r["hard"])             # CG shim not mapped in this test
        self.assertFalse(any(s.startswith("Foundation/") for s in r["hard"]))

    def test_weak_definition_coalescing_uses_sdk_exports(self):
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        # dyld_info uses this pseudo-library for Unity's aligned C++ allocation imports.
        with patch.object(shackprep, "bind_targets", return_value={"<weak-def-coalesce>": {
            "__ZnwmSt11align_val_t": False, "_macshack_missing_coalesced_symbol": False}}):
            report = shackprep.gap_report2(self.app, sdk, shim_dir=None)[self.exe]
        self.assertNotIn("<weak-def-coalesce>/__ZnwmSt11align_val_t", report["hard"])
        self.assertIn("<weak-def-coalesce>/_macshack_missing_coalesced_symbol", report["hard"])

    def test_rpaths_follow_the_guest_not_the_host(self):
        fw = os.path.join(self.app, "Contents", "Frameworks", "lib.dylib")
        os.makedirs(os.path.dirname(fw))
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", "-dynamiclib", "-x", "c", "/dev/null",
                               "-Wl,-rpath,@executable_path", "-Wl,-rpath,@executable_path/../Frameworks", "-o", fw])
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", HELLO_SRC,
                               "-Wl,-rpath,@executable_path", "-o", self.exe])
        exe_dir = os.path.dirname(self.exe)
        shackprep.rewrite_links(self.exe, {}, exe_dir); shackprep.rewrite_links(fw, {}, exe_dir)
        self.assertIn("path @loader_path/. ", otool_l(self.exe))
        self.assertIn("path @loader_path/../MacOS ", otool_l(fw))
        self.assertIn("path @loader_path/../Frameworks ", otool_l(fw))
        self.assertNotIn("@executable_path", otool_l(fw) + otool_l(self.exe))

    def test_embedded_frameworks_become_shallow(self):
        fw = os.path.join(self.app, "Contents", "MacOS", "Lib.framework")
        os.makedirs(os.path.join(fw, "Versions", "A", "Resources"))
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "arm64-apple-macos13.0", "-dynamiclib", "-x", "c", "/dev/null",
                               "-install_name", "@rpath/Lib.framework/Versions/A/Lib", "-o", os.path.join(fw, "Versions", "A", "Lib")])
        with open(os.path.join(fw, "Versions", "A", "Resources", "Info.plist"), "w") as f: f.write("<plist/>")
        os.symlink("A", os.path.join(fw, "Versions", "Current")); os.symlink("Versions/Current/Lib", os.path.join(fw, "Lib"))
        out = os.path.join(self.tmp, "code"); shackprep.copy_code(self.app, out)
        got = os.path.join(out, "Contents", "MacOS", "Lib.framework")
        self.assertTrue(os.path.isfile(os.path.join(got, "Lib")) and os.path.isfile(os.path.join(got, "Info.plist")))
        self.assertFalse(os.path.exists(os.path.join(got, "Versions")))

    def test_skips_dsyms_and_reports_intel_only_plugins(self):
        plug = os.path.join(self.app, "Contents", "PlugIns", "helper.dylib")
        os.makedirs(os.path.dirname(plug))
        subprocess.check_call(["clang", "-isysroot", MACSDK, "-target", "x86_64-apple-macos13.0", "-dynamiclib",
                               "-x", "c", "/dev/null", "-o", plug])
        dsym = os.path.join(self.app, "Contents", "MacOS", "Hello.dSYM", "Contents", "Resources", "DWARF")
        os.makedirs(dsym); shutil.copy(self.exe, os.path.join(dsym, "Hello"))
        self.assertNotIn(os.path.join(dsym, "Hello"), list(shackprep.machos_in(self.app)))
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        r = shackprep.gap_report2(self.app, sdk, shim_dir=None)
        self.assertEqual(r[plug]["hard"], ["<no arm64 slice: cannot run on iOS>"])
        out = shackprep.prep_bundle(self.app, os.path.join(self.tmp, "out.app"))   # prep drops it from its copy only
        self.assertFalse(os.path.exists(os.path.join(out, "Contents", "PlugIns", "helper.dylib")))
        self.assertTrue(os.path.exists(plug))

    def test_framework_exports_reads_the_swift_runtime(self):
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        self.assertEqual(shackprep.framework_name("/usr/lib/swift/libswiftCore.dylib"), "libswiftCore")
        self.assertIn("_swift_allocObject", shackprep.framework_exports(sdk, "libswiftCore"))
        # dyld_info names /usr/lib/libbz2.1.0.dylib "libbz2.1"; the SDK stub is libbz2.1.0.tbd (Crimson Desert's metal IR converter)
        self.assertIn("_BZ2_bzDecompress", shackprep.framework_exports(sdk, "libbz2.1"))

    def test_framework_exports_follows_reexports(self):
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        self.assertIn("_AVFormatIDKey", shackprep.framework_exports(sdk, "AVFoundation"))   # AVFAudio re-export
        self.assertIn("_exp2", shackprep.framework_exports(sdk, "libSystem"))

    def test_parse_fixups_skips_dyld_info_garbage(self):
        out = shackprep.parse_fixups("        __DATA  __la_symbol_ptr  0x306A48  bind  <invalid-lib-ordinal>/(null)\n"
                                     "        __DATA  __la_symbol_ptr  0x306A58  bind  <this-image>/x + 0x7683475AE0\n")
        self.assertEqual(out, {})

if __name__ == "__main__":
    unittest.main()
