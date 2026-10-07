// Mac check: swiftc -parse-as-library host/StagedFolder.swift host/probe/test_staged_folder.swift -o /tmp/t && /tmp/t
// expect `staged folder ok`.
import Foundation

@main struct TestStagedFolder {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("staged-folder-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("Staging"), games = root.appendingPathComponent("Games")
        let folder = staging.appendingPathComponent("Cyberpunk 2077")
        for dir in ["Cyberpunk2077.app/Contents/MacOS", "archive/Mac/content", "r6"] {
            try fm.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: folder.appendingPathComponent("archive/Mac/content/basegame.archive"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: staging.appendingPathComponent("Two/A.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("Two/B.app"), withIntermediateDirectories: true)

        let app = StagedFolder.game(in: folder)
        check(app?.lastPathComponent == "Cyberpunk2077.app", "the folder's one .app is listed")
        check(StagedFolder.game(in: staging.appendingPathComponent("Two")) == nil, "a folder with two apps is not")
        check(StagedFolder.game(in: app!) == nil, "an .app is not a game folder")

        try fm.createDirectory(at: games.appendingPathComponent("r6"), withIntermediateDirectories: true)
        check((try? StagedFolder.unpack(app!, staging: staging, games: games)) == nil, "a name already in Games is refused")
        check(fm.fileExists(atPath: folder.appendingPathComponent("archive").path), "and nothing moved")
        try fm.removeItem(at: games.appendingPathComponent("r6"))

        let installed = try StagedFolder.unpack(app!, staging: staging, games: games)
        check(installed.path == staging.appendingPathComponent("Cyberpunk2077.app").path, "the .app goes to Staging's top")
        check(fm.fileExists(atPath: games.appendingPathComponent("archive/Mac/content/basegame.archive").path), "data beside the game")
        check(fm.fileExists(atPath: games.appendingPathComponent("r6").path), "every data item")
        check(!fm.fileExists(atPath: folder.path), "the emptied folder is gone")
        check(try StagedFolder.unpack(installed, staging: staging, games: games).path == installed.path, "a top-level .app is left as is")
        let installedGame = games.appendingPathComponent("Other.app")   // Prepare again of an installed game
        try fm.createDirectory(at: installedGame, withIntermediateDirectories: true)
        check(try StagedFolder.unpack(installedGame, staging: staging, games: games).path == installedGame.path, "an installed .app is left as is")
        check(fm.fileExists(atPath: games.appendingPathComponent("archive").path), "and Games is untouched")
        try fm.removeItem(at: root)
        print("staged folder ok")
    }
}
