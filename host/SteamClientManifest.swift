import CryptoKit
import Foundation

// Valve's macOS Steam client manifest (client-update.fastly.steamstatic.com/steam_client_osx; the pin is
// host/steam_client_osx.manifest): text VDF, `"osx" { "version" ..., <package> { "file" "size" "sha2" ... } }`. A package's
// `macos-signed-2` block, when it has one, wins: that steam_osx is the build Steam on a Mac runs (the top-level one is a
// different binary). `steamchina` blocks are never used.
struct SteamClientManifest {
    struct Package: Equatable {
        let name: String, file: String, sha2: String
        let size: Int64
    }

    let version: String
    let packages: [Package]   // sorted by name
    let data: Data            // the manifest as Valve published it

    init?(data: Data) {
        guard let osx = VDFParser.parseTextVDF(from: data)["osx"] as? [String: Any],
              let version = osx["version"] as? String else { return nil }
        self.version = version
        self.data = data
        let list = osx.compactMap { name, value -> Package? in
            guard let block = value as? [String: Any] else { return nil }
            let entry = block["macos-signed-2"] as? [String: Any] ?? block
            guard let file = entry["file"] as? String, let sha2 = entry["sha2"] as? String,
                  let size = (entry["size"] as? String).flatMap({ Int64($0) }) else { return nil }
            return Package(name: name, file: file, sha2: sha2, size: size)
        }.sorted { $0.name < $1.name }
        // A file name from Valve becomes a cache path and a URL: one that is not a plain name refuses the manifest.
        guard !list.contains(where: { $0.file.isEmpty || $0.file == "." || $0.file == ".." || $0.file.contains("/") || $0.file.contains("\\") }) else { return nil }
        packages = list
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    // The packages to download: those whose file differs from the installed manifest's (all without one).
    func changed(since installed: SteamClientManifest?) -> [Package] {
        guard let installed else { return packages }
        let old = Dictionary(installed.packages.map { ($0.name, $0.sha2) }, uniquingKeysWith: { a, _ in a })
        return packages.filter { old[$0.name] != $0.sha2 }
    }

    // A downloaded package's sha256 as the manifest writes it (lowercase hex), nil when it cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        var failed = false
        // Each chunk drained at once: on a worker thread the pool would otherwise hold the whole file.
        while autoreleasepool(invoking: { () -> Bool in
            do {
                guard let chunk = try file.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                hash.update(data: chunk)
                return true
            } catch { failed = true; return false }
        }) {}
        return failed ? nil : hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
