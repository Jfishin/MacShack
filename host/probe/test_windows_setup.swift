// Mac check for host/WindowsKit.swift: the downloads and their pins, the layout MacShack Play reads, NotProton's ntdll
// detour (applied once, "already patched" after, refused on another file), the libraries to sign, the credits.
// Downloads Madeira's IPA and Valve's two packages once into ~/Library/Caches/MacShackWindowsSetupTest; the kit zip is
// the argument (windows-kit/release.sh's build/macshack-windows-kit-1.zip) until its release is public. From the
// repository root:
// clang -fobjc-arc -c host/ShackSteamSetup.m -o /tmp/ss.o && swiftc -parse-as-library -import-objc-header host/ShackSteamSetup.h \
//   host/VDFParser.swift host/SteamClientManifest.swift host/WindowsKit.swift host/probe/test_windows_setup.swift /tmp/ss.o \
//   -larchive -o /tmp/t && /tmp/t windows-kit/build/macshack-windows-kit-1.zip
// Expect `windows setup ok`.
import Foundation

@main struct TestWindowsSetup {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
    static let fm = FileManager.default

    static func main() async {
        guard CommandLine.arguments.count > 1 else { print("usage: t <macshack-windows-kit-N.zip>"); exit(2) }
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MacShackWindowsSetupTest")
        try! fm.createDirectory(at: cache, withIntermediateDirectories: true)
        // The kit from the argument, the rest from their makers, as the device gets them.
        let kitCopy = cache.appendingPathComponent(WindowsKit.kit.file)
        try? fm.removeItem(at: kitCopy)
        try! fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: kitCopy)
        check(WindowsKit.downloads.first == WindowsKit.kit, "the kit is fetched first: an unpublished kit fails before Madeira's 146 MB")
        for d in WindowsKit.downloads where d != WindowsKit.kit {
            let file = cache.appendingPathComponent(d.file)
            if SteamClientManifest.sha256(of: file) == d.sha256 { continue }
            print("downloading \(d.name)")
            let (tmp, response) = try! await URLSession.shared.download(from: d.url)
            check((response as? HTTPURLResponse)?.statusCode == 200, "\(d.url) answers 200")
            try? fm.removeItem(at: file)
            try! fm.moveItem(at: tmp, to: file)
        }
        for d in WindowsKit.downloads {
            check(SteamClientManifest.sha256(of: cache.appendingPathComponent(d.file)) == d.sha256, "\(d.name) matches its pin")
            check(d.url.scheme == "https", "\(d.name) comes over https")
        }

        let root = fm.temporaryDirectory.appendingPathComponent("windows-setup-\(UUID().uuidString)/Windows.new")
        let libraries = try! WindowsKit.layOut(cache: cache, into: root, unzip: { ShackSteamUnzip($0, $1) })
        let engine = root.appendingPathComponent("engine")
        let laidOut = WindowsKit.engineItems + ["arm64ec-windows/lsteamclient.dll", "aarch64-unix/lsteamclient.so", "steamapi-test.exe",
                                                "steam/steam.exe", "steam/msi.dll", "steam/macshack-launch.exe"]
            + WindowsKit.valveFiles.map { "steam/\($0.name)" }
        for item in laidOut { check(fm.fileExists(atPath: engine.appendingPathComponent(item).path), "engine/\(item) is laid out") }
        check(!fm.fileExists(atPath: engine.appendingPathComponent("i386-windows").path), "no i386-windows")
        for notice in ["LICENSE", "NOTICE", "SOURCE", "notproton/NOTICE", "ntdll.patch.json"] {
            check(fm.fileExists(atPath: root.appendingPathComponent("kit/\(notice)").path), "kit/\(notice) is kept")
        }
        let base = engine.resolvingSymlinksInPath().path + "/"
        let names = libraries.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        check(names.contains("Madeira.debug.dylib") && names.contains("aarch64-unix/lsteamclient.so"), "the engine and lsteamclient.so are to be signed: \(names)")
        check(!names.contains { $0.hasSuffix(".dll") || $0.hasSuffix(".exe") }, "no Windows file is to be signed")

        // The detour: in once (layOut applied it), and refused on a file it is not for.
        let patch = try! Data(contentsOf: root.appendingPathComponent("kit/ntdll.patch.json"))
        check((try? WindowsKit.applyPatch(patch, under: engine)) == "already patched", "the detour is in once")
        let other = fm.temporaryDirectory.appendingPathComponent("windows-setup-other-\(UUID().uuidString)")
        try! fm.createDirectory(at: other.appendingPathComponent("arm64ec-windows"), withIntermediateDirectories: true)
        try! Data("not ntdll".utf8).write(to: other.appendingPathComponent("arm64ec-windows/ntdll.dll"))
        check((try? WindowsKit.applyPatch(patch, under: other)) == nil, "the detour refuses another ntdll.dll")

        check(WindowsKit.credits.count == 5 && WindowsKit.credits.allSatisfy { $0.link.scheme == "https" }, "five credits, each with a link")
        check(WindowsKit.stamp.sha256.count == WindowsKit.downloads.count, "the stamp names every download")
        try? fm.removeItem(at: root.deletingLastPathComponent())
        try? fm.removeItem(at: other)
        print("windows setup ok")
    }
}
