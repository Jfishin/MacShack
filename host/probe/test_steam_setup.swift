// Mac check for Steam client setup (host/SteamClientManifest.swift, host/ShackSteamSetup.m): the pinned manifest's
// packages, unsafe archives refused, and the pinned packages unpacked exactly as Valve's own install of that version
// (`steam_client_signed-2_osx.installed` of the Mac's Steam: path,size;mtime;crc32, size -1 folder, -2 symlink).
// Downloads ~412 MB from Valve's CDN once into ~/Library/Caches/MacShackSteamSetupTest. From the repository root:
// clang -fobjc-arc -c host/ShackSteamSetup.m -o /tmp/ss.o && swiftc -parse-as-library -import-objc-header host/ShackSteamSetup.h \
//   host/VDFParser.swift host/SteamClientManifest.swift host/probe/test_steam_setup.swift /tmp/ss.o -larchive -o /tmp/t && /tmp/t
// Expect `steam setup ok` (the compare is skipped, and says so, when the Mac's Steam is not at the pinned version).
import Foundation
import zlib

@main struct TestSteamSetup {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
    static let fm = FileManager.default
    static let cdn = URL(string: "https://client-update.fastly.steamstatic.com/")!

    static func main() async {
        let pinPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "host/steam_client_osx.manifest"
        guard let pin = SteamClientManifest(contentsOf: URL(fileURLWithPath: pinPath)) else { check(false, "pin parses"); return }

        // The manifest: every package once, the Mac's steam_osx build, no Steam China files.
        let names = pin.packages.map(\.name)
        check(Set(names).count == names.count && names.contains("appdmg_osx") && names.contains("webkit_osx"), "package list")
        check(pin.packages.first { $0.name == "steam_osx" }?.file.hasPrefix("steam_osx_macos-signed-2.zip.") == true, "steam_osx is the macos-signed-2 build")
        check(!pin.packages.contains { $0.file.contains("steamchina") }, "no steamchina files")
        check(pin.changed(since: nil) == pin.packages && pin.changed(since: pin).isEmpty, "changed: all without an install, none against itself")
        let one = pin.packages.first { $0.name == "strings_all" }!
        let edited = String(decoding: pin.data, as: UTF8.self).replacingOccurrences(of: one.sha2, with: String(repeating: "0", count: 64))
        check(pin.changed(since: SteamClientManifest(data: Data(edited.utf8))).map(\.name) == ["strings_all"], "changed: one edited package")
        let unsafe = String(decoding: pin.data, as: UTF8.self).replacingOccurrences(of: one.file, with: "../\(one.file)")
        check(SteamClientManifest(data: Data(unsafe.utf8)) == nil, "a file name with a path in it refuses the manifest")

        // Unsafe archives stop before writing anything outside.
        let scratch = fm.temporaryDirectory.appendingPathComponent("steam-setup-\(UUID().uuidString)")
        let evil = scratch.appendingPathComponent("evil"), into = scratch.appendingPathComponent("into/MacOS")
        try! fm.createDirectory(at: evil, withIntermediateDirectories: true)
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-c", """
            import zipfile, sys
            d = sys.argv[1]
            for name, entry, data, link in [("dotdot", "../escaped", b"x", False), ("backslash", "a\\\\..\\\\..\\\\escaped", b"x", False),
                                            ("absolute", "/tmp/macshack-escaped", b"x", False), ("link", "a/link", b"../../escaped", True)]:
                with zipfile.ZipFile(f"{d}/{name}.zip", "w") as z:
                    info = zipfile.ZipInfo(entry)
                    if link:
                        info.create_system = 3
                        info.external_attr = 0o120755 << 16
                    z.writestr(info, data)
            """, evil.path]
        try! python.run(); python.waitUntilExit()
        for name in ["dotdot", "backslash", "absolute", "link"] {
            let failure = ShackSteamUnzip(evil.appendingPathComponent("\(name).zip").path, into.path)
            check(failure != nil, "\(name).zip refused")
            print("refused \(name).zip: \(failure ?? "")")
        }
        check(!fm.fileExists(atPath: scratch.appendingPathComponent("into/escaped").path) &&
              !fm.fileExists(atPath: scratch.appendingPathComponent("escaped").path) &&
              !fm.fileExists(atPath: "/tmp/macshack-escaped"), "nothing written outside")
        try? fm.removeItem(at: into)

        // The pinned packages, downloaded once, checked, unpacked like SteamSetup does.
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacShackSteamSetupTest")
        try! fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let contents = scratch.appendingPathComponent("Steam/Contents")
        for p in pin.packages {
            let zip = cache.appendingPathComponent(p.file)
            if SteamClientManifest.sha256(of: zip) != p.sha2 {
                print("downloading \(p.file) (\(p.size / 1_000_000) MB)")
                let (tmp, response) = try! await URLSession.shared.download(from: cdn.appendingPathComponent(p.file))
                check((response as? HTTPURLResponse)?.statusCode == 200, "\(p.file) on Valve's CDN")
                try? fm.removeItem(at: zip)
                try! fm.moveItem(at: tmp, to: zip)
            }
            check(SteamClientManifest.sha256(of: zip) == p.sha2, "\(p.file) sha256")
            let failure = ShackSteamUnzip(zip.path, contents.appendingPathComponent("MacOS").path)
            check(failure == nil, "\(p.name) unpacks: \(failure ?? "")")
        }
        let skeleton = ShackSteamUnpackSkeleton(contents.appendingPathComponent("MacOS/SteamMacBootstrapper.tar.gz").path, contents.path)
        check(skeleton == nil, "skeleton unpacks: \(skeleton ?? "")")
        for file in ["Info.plist", "embedded.provisionprofile", "Resources/Assets.car", "Resources/Steam.icns"] {
            check(fm.fileExists(atPath: contents.appendingPathComponent(file).path), "skeleton \(file)")
        }

        // Valve's own record of this version's install, when the Mac's Steam is at it.
        let package = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/package")
        let macVersion = SteamClientManifest(contentsOf: package.appendingPathComponent("steam_client_signed-2_osx.manifest"))?.version
        if macVersion != pin.version {
            print("SKIP compare: the Mac's Steam is at \(macVersion ?? "none"), the pin at \(pin.version)")
        } else {
            let macOS = contents.appendingPathComponent("MacOS")
            let record = try! String(contentsOf: package.appendingPathComponent("steam_client_signed-2_osx.installed"), encoding: .utf8)
            var compared = 0
            for line in record.split(separator: "\n") where line.contains(";") {
                guard let comma = line.lastIndex(of: ",") else { continue }
                let path = String(line[..<comma]), fields = line[line.index(after: comma)...].split(separator: ";")
                let size = Int64(fields[0])!, crc = UInt32(fields[2])!
                let url = macOS.appendingPathComponent(path)
                switch size {
                case -1:
                    var dir: ObjCBool = false
                    check(fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue, "folder \(path)")
                case -2:
                    let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
                    check(target.map { crc32Of(Data($0.utf8)) } == crc, "symlink \(path) -> \(target ?? "missing")")
                default:
                    let data = try? Data(contentsOf: url)
                    check(data?.count == Int(size) && data.map(crc32Of) == crc, "file \(path): \(data?.count ?? -1) of \(size) bytes")
                }
                compared += 1
            }
            print("matches Valve's install of \(pin.version): \(compared) entries")
        }
        try? fm.removeItem(at: scratch)
        print("steam setup ok")
    }

    static func crc32Of(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
}
