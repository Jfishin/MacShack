import SwiftUI
import UIKit

// Tile art: the app icon from the game's own .icns.
@MainActor
enum Artwork {
    private static let memory = NSCache<NSString, UIImage>()

    // Files are read, parsed and decoded off the main thread: UIImage decodes lazily at first draw otherwise, which
    // is on the main thread in the middle of a scroll (the game grid stuttered).
    static func icon(forApp app: URL) async -> UIImage? {
        let key = app.path as NSString
        if let hit = memory.object(forKey: key) { return hit }
        guard let image = await Task.detached(priority: .userInitiated, operation: { loadIcon(app) }).value else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    private nonisolated static func loadIcon(_ app: URL) -> UIImage? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              var name = info["CFBundleIconFile"] as? String, !name.isEmpty else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".icns" }
        let file = app.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file), let bytes = ICNS.bestImage(in: data) else { return nil }
        return UIImage(data: bytes)?.preparingForDisplay()
    }
}

// Square icon, with a lettered placeholder while loading or when there is no art.
struct ArtTile: View {
    let title: String
    var focused = false   // controller focus: white ring
    let load: () async -> UIImage?
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Text(String(title.prefix(1))).font(.largeTitle.bold()).foregroundStyle(.secondary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white, lineWidth: 4) }
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .task(id: title) { image = await load() }
    }
}
