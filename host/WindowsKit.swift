import Foundation

// Windows games' pieces (README, "Windows games"; windows-kit/README.md): what is downloaded and from whom,
// and how it is laid out in the App Group's Windows folder for MacShack Play. No UI and no signing here
// (WindowsSetup.swift), so the Mac check runs all of it: host/probe/test_windows_setup.swift.
enum WindowsKit {
    struct Download: Equatable {
        let name: String, url: URL, sha256: String
        var file: String { url.lastPathComponent }
    }

    // Will Faust's release, as he publishes it (GPL-3.0-or-later): only its engine is kept.
    static let madeiraVersion = "0.1.3"
    static let madeira = Download(name: "Madeira \(madeiraVersion)",
                                  url: URL(string: "https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa")!,
                                  sha256: "71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0")
    // windows-kit/release.sh's zip, a release of this repository (GPL-3.0; its SOURCE names its exact source).
    static let kitVersion = 1
    static let kit = Download(name: "MacShack Windows kit \(kitVersion)",
                              url: URL(string: "https://github.com/Jfishin/MacShack/releases/download/windows-kit-1/macshack-windows-kit-1.zip")!,
                              sha256: "ee082a5d261353fe14e59f422bb6fb1ad1098e94aaf7e5b58fa670a840052f50")
    // Valve's Steam client packages NotProton v1.0.3 takes Steam's Windows files from (its valve-packages.manifest), from
    // the CDN Steam setup uses (SteamSetup.cdn). Downloaded on this device, never redistributed.
    static let valveCDN = URL(string: "https://client-update.fastly.steamstatic.com/")!
    static let valvePackages = [
        Download(name: "Valve's bins_misc_ubuntu12", url: valveCDN.appendingPathComponent("bins_misc_ubuntu12.zip.3f92810725ee673827371a0470cd4f8c7ea8cfae"),
                 sha256: "026b984726c728bbf81ae3ba16623bcd96e2bf837a859c235acf0ee279d940fd"),
        Download(name: "Valve's bins_win64", url: valveCDN.appendingPathComponent("bins_win64.zip.36f5d9202e79ab2aa3e3c5902e84bbd799d31fc0"),
                 sha256: "93f5b6bea0267fd85dc8cc823fdab5c5fb55d7f3a1deab0598acefef0e133bce"),
    ]
    struct ValveFile { let name: String, package: Int, path: String, sha256: String }   // package: index in valvePackages
    static let valveFiles = [
        ValveFile(name: "steamclient.dll", package: 0, path: "legacycompat/steamclient.dll", sha256: "e9e961c914a418b6a3c597822bdc920bdea62c842ff42de23dc306331da563f8"),
        ValveFile(name: "steamclient64.dll", package: 0, path: "steamclient64.dll", sha256: "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee"),
        ValveFile(name: "tier0_s64.dll", package: 1, path: "tier0_s64.dll", sha256: "30f7bb8d9b86006852493c26124ba253bd9e7ffd40a8b3c7254f86a9032c3be3"),
        ValveFile(name: "vstdlib_s64.dll", package: 1, path: "vstdlib_s64.dll", sha256: "99efb4c2ad47f90c803b5ee0bd6424916b28facb9fa2568845b1b1f58a36062a"),
    ]
    // The kit first: a kit not (yet) published fails before the 146 MB Madeira download. layOut reads the cache by file name.
    static var downloads: [Download] { [kit, madeira] + valvePackages }

    // From Madeira's app: its engine and the files it reads beside it. Not: i386-windows (194 MB, until a 32-bit game
    // needs it), Madeira's own app, JIT extension and frameworks.
    static let engineItems = ["Madeira.debug.dylib", "default.metallib", "aarch64-windows", "arm64ec-windows", "x86_64-vcruntime",
                              "nls", "d3d12", "prefix-template.tar.gz", "cacert.pem", "legal", "licenses"]

    // Who made each piece: shown before anything downloads (WindowsGamesView).
    struct Credit: Identifiable {
        let piece: String, maker: String, license: String, link: URL
        var id: String { piece }
    }
    static let credits = [
        Credit(piece: "Windows engine (Wine, FEX and DXMT inside)", maker: "Madeira, by Will Faust",
               license: "GPL-3.0-or-later with the Madeira Converter Exception; Wine LGPL-2.1-or-later",
               link: URL(string: "https://github.com/willfaust/Madeira")!),
        Credit(piece: "Steam bridge for Windows games", maker: "NotProton", license: "GPL-3.0",
               link: URL(string: "https://github.com/NotProtonNot/NotProton")!),
        Credit(piece: "lsteamclient and steam.exe", maker: "Valve's Proton, through NotProton",
               license: "Steamworks SDK license; BSD-3-Clause", link: URL(string: "https://github.com/ValveSoftware/Proton")!),
        Credit(piece: "Steam's Windows files", maker: "Valve, downloaded from Valve", license: "Steam Subscriber Agreement",
               link: URL(string: "https://store.steampowered.com/subscriber_agreement/")!),
        Credit(piece: "Kit build and helpers", maker: "MacShack", license: "GPL-3.0-or-later (windows-kit/)",
               link: URL(string: "https://github.com/Jfishin/MacShack/tree/main/windows-kit")!),
    ]

    // Windows/setup.json, written last (WindowsSetup): its presence is "set up" (ShackWindowsGamesSetUp).
    struct Stamp: Codable, Equatable { var madeira: String; var kit: Int; var sha256: [String: String] }
    static var stamp: Stamp {
        Stamp(madeira: madeiraVersion, kit: kitVersion, sha256: Dictionary(uniqueKeysWithValues: downloads.map { ($0.file, $0.sha256) }))
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// `root` (Windows.new) from the verified downloads in `cache`: engine/ shaped as Madeira's app bundle (its engine
    /// items; the kit's lsteamclient halves and steamapi-test.exe; steam/ with Valve's four files and the kit's steam.exe,
    /// msi.dll, macshack-launch.exe), NotProton's detour in its ntdll.dll, kit/ with the kit's notices. `unzip` is
    /// ShackSteamUnzip (nil on success). Returns the Mach-O libraries to sign for MacShack Play.
    static func layOut(cache: URL, into root: URL, unzip: (String, String) -> String?) throws -> [URL] {
        let fm = FileManager.default
        let engine = root.appendingPathComponent("engine"), kitDir = root.appendingPathComponent("kit")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: engine, withIntermediateDirectories: true)
        func unpack(_ download: Download, into dir: URL) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let failure = unzip(cache.appendingPathComponent(download.file).path, dir.path) { throw Failure("\(download.name): \(failure)") }
        }
        // Madeira's engine, out of its app.
        let ipa = root.appendingPathComponent("ipa"), app = ipa.appendingPathComponent("Payload/Madeira.app")
        try unpack(madeira, into: ipa)
        for item in engineItems where fm.fileExists(atPath: app.appendingPathComponent(item).path) {
            try fm.moveItem(at: app.appendingPathComponent(item), to: engine.appendingPathComponent(item))
        }
        try fm.removeItem(at: ipa)
        guard fm.fileExists(atPath: engine.appendingPathComponent("Madeira.debug.dylib").path) else { throw Failure("\(madeira.name) has no Madeira.debug.dylib") }
        // The kit: its pieces where the engine and Play look for them, its notices and the detour in kit/.
        try unpack(kit, into: kitDir)
        for dir in ["steam", "aarch64-unix"] { try fm.createDirectory(at: engine.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for piece in ["arm64ec-windows/lsteamclient.dll", "aarch64-unix/lsteamclient.so", "steamapi-test.exe",
                      "steam/steam.exe", "steam/msi.dll", "steam/macshack-launch.exe"] {
            try fm.moveItem(at: kitDir.appendingPathComponent(piece), to: engine.appendingPathComponent(piece))
        }
        // Valve's four files, each checked against NotProton's pin.
        for (index, package) in valvePackages.enumerated() {
            let dir = root.appendingPathComponent("valve\(index)")
            try unpack(package, into: dir)
            for file in valveFiles where file.package == index {
                let from = dir.appendingPathComponent(file.path)
                guard SteamClientManifest.sha256(of: from) == file.sha256 else { throw Failure("Valve's \(file.name) does not match its pin") }
                try fm.moveItem(at: from, to: engine.appendingPathComponent("steam/\(file.name)"))
            }
            try fm.removeItem(at: dir)
        }
        _ = try applyPatch(Data(contentsOf: kitDir.appendingPathComponent("ntdll.patch.json")), under: engine)
        return libraries(in: engine)
    }

    /// The Mach-O files under `engine` (the engine, d3d12's, lsteamclient.so): what MacShack Play loads, so what is signed.
    static func libraries(in engine: URL) -> [URL] {
        let walk = FileManager.default.enumerator(at: engine, includingPropertiesForKeys: [.isRegularFileKey])
        return (walk?.allObjects as? [URL] ?? []).filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            let magic = (try? file.read(upToCount: 4)) ?? Data()
            return magic == Data([0xcf, 0xfa, 0xed, 0xfe]) || magic == Data([0xca, 0xfe, 0xba, 0xbe])   // thin arm64, universal
        }.sorted { $0.path < $1.path }
    }

    private struct Patch: Decodable {
        struct Write: Decodable { let offset: Int; let bytes: String }
        let file: String, original: String, result: String
        let writes: [Write]
    }

    /// The kit's ntdll.patch.json applied under `engine`: the original's sha256 checked first and the result's after;
    /// "already patched" when the file is the result already.
    static func applyPatch(_ json: Data, under engine: URL) throws -> String {
        let patch = try JSONDecoder().decode(Patch.self, from: json)
        guard !patch.file.split(separator: "/").contains("..") else { throw Failure("the kit's patch names \(patch.file)") }
        let url = engine.appendingPathComponent(patch.file)
        let now = SteamClientManifest.sha256(of: url)
        if now == patch.result { return "already patched" }
        guard now == patch.original else { throw Failure("\(patch.file) is not the file the kit's patch is for") }
        var data = try Data(contentsOf: url)
        for write in patch.writes {
            guard let bytes = Data(hex: write.bytes), write.offset >= 0, write.offset + bytes.count <= data.count else {
                throw Failure("\(patch.file): a write of the kit's patch lies outside the file")
            }
            data.replaceSubrange(write.offset ..< write.offset + bytes.count, with: bytes)
        }
        let fresh = url.appendingPathExtension("new")
        try data.write(to: fresh)
        guard SteamClientManifest.sha256(of: fresh) == patch.result else {
            try? FileManager.default.removeItem(at: fresh)
            throw Failure("\(patch.file): the patched file is not the kit's result")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: fresh)
        return "patched \(patch.writes.count) range(s)"
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i ..< j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        self.init(bytes)
    }
}
