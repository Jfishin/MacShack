import Foundation

@MainActor
enum SteamLaunch {
    // A game's Steam app ID: steam_appid.txt in the bundle, or a Documents/Games/<Name>.steam sidecar.
    static func appID(for game: URL) -> UInt32? {
        let sidecar = game.deletingPathExtension().appendingPathExtension("steam")
        for file in [sidecar, game.appendingPathComponent("Contents/MacOS/steam_appid.txt"),
                     game.appendingPathComponent("Contents/Resources/steam_appid.txt")] {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let id = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 { return id }
        }
        return nil
    }
}
