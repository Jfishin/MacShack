import Foundation

// A Mac game folder copied into Staging whole: its one .app with the data beside it (Cyberpunk 2077: archive/, engine/,
// r6/, tools/), the layout a game reads from the folder that holds its .app. Home lists the .app; Prepare unpacks the
// folder: the data moves beside the installed game (Documents/Games) and the .app to Staging's top, where the installer
// takes it. Only on Prepare, never while scanning: Files may still be copying. Names already in Documents/Games are
// refused rather than mixing two games' data.
enum StagedFolder {
    static func game(in folder: URL) -> URL? {
        guard folder.pathExtension != "app", (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let apps = items.filter { $0.pathExtension == "app" }
        return apps.count == 1 ? apps[0] : nil
    }

    // The .app to install: app itself unless it is in a folder directly inside Staging (at Staging's top, or installed in
    // Documents/Games for a Prepare again).
    static func unpack(_ app: URL, staging: URL, games: URL) throws -> URL {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == staging.standardizedFileURL.path else { return app }
        func fail(_ text: String) -> NSError { NSError(domain: "MacShack", code: 4, userInfo: [NSLocalizedDescriptionKey: text]) }
        let leftover = { (name: String) in name == ".DS_Store" || name.hasPrefix("._") }
        let data = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != app.lastPathComponent && !leftover($0.lastPathComponent) }
        let dest = staging.appendingPathComponent(app.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { throw fail("Staging already has \(app.lastPathComponent).") }
        if let taken = data.first(where: { fm.fileExists(atPath: games.appendingPathComponent($0.lastPathComponent).path) }) {
            throw fail("Documents/Games already has \(taken.lastPathComponent) (another game's data?). Move it away and Prepare again.")
        }
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        for item in data {
            try fm.moveItem(at: item, to: games.appendingPathComponent(item.lastPathComponent))
            NSLog("[MacShack] %@: %@ moved beside the game in Documents/Games", folder.lastPathComponent, item.lastPathComponent)
        }
        try fm.moveItem(at: app, to: dest)
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.allSatisfy(leftover) == true { try? fm.removeItem(at: folder) }
        return dest
    }
}
