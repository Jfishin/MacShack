import SwiftUI
import ImageIO

// Five numbers make a look: the accent (hue, saturation, brightness) and the background tint (hue, strength). The
// background's own brightness follows light/dark mode, so no slider position makes text unreadable.
struct Palette: Codable, Equatable {
    var accentHue = 0.6, accentSat = 0.7, accentBri = 1.0
    var bgHue = 0.65, bgSat = 0.5

    var accent: Color { Color(hue: accentHue, saturation: accentSat, brightness: accentBri) }
    func background(dark: Bool) -> [Color] {
        dark ? [Color(hue: bgHue, saturation: bgSat, brightness: 0.26), Color(hue: bgHue, saturation: bgSat, brightness: 0.09)]
             : [Color(hue: bgHue, saturation: bgSat * 0.3, brightness: 0.98), Color(hue: bgHue, saturation: bgSat * 0.55, brightness: 0.86)]
    }
}

// The chosen theme, the custom sliders and the Local Games picture, kept in UserDefaults and Application Support.
@Observable
@MainActor
final class Appearance {
    static let system = "System", custom = "Custom"
    static let presets: [(name: String, palette: Palette)] = [
        ("Midnight", Palette(accentHue: 0.62, accentSat: 0.65, accentBri: 1.0, bgHue: 0.66, bgSat: 0.65)),
        ("Ocean", Palette(accentHue: 0.56, accentSat: 0.9, accentBri: 0.85, bgHue: 0.55, bgSat: 0.6)),
        ("Forest", Palette(accentHue: 0.38, accentSat: 0.8, accentBri: 0.65, bgHue: 0.40, bgSat: 0.55)),
        ("Sunset", Palette(accentHue: 0.03, accentSat: 0.85, accentBri: 0.9, bgHue: 0.98, bgSat: 0.55)),
        ("Grape", Palette(accentHue: 0.77, accentSat: 0.65, accentBri: 0.9, bgHue: 0.76, bgSat: 0.55)),
        ("Rose", Palette(accentHue: 0.94, accentSat: 0.65, accentBri: 0.9, bgHue: 0.92, bgSat: 0.45)),
    ]

    var choice = UserDefaults.standard.string(forKey: "theme") ?? Appearance.system {
        didSet { UserDefaults.standard.set(choice, forKey: "theme") }
    }
    var customPalette = (UserDefaults.standard.data(forKey: "themeCustom").flatMap { try? JSONDecoder().decode(Palette.self, from: $0) }) ?? Palette() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(customPalette), forKey: "themeCustom") }
    }
    var dim = UserDefaults.standard.object(forKey: "homeDim") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(dim, forKey: "homeDim") }
    }
    private(set) var picture: UIImage? = UIImage(contentsOfFile: Appearance.pictureFile.path)

    var palette: Palette? {
        choice == Self.system ? nil : choice == Self.custom ? customPalette : Self.presets.first { $0.name == choice }?.palette
    }
    var accent: Color? { palette?.accent }

    // A preset also seeds the sliders, so dragging one starts from the look you picked.
    func select(_ name: String) {
        if let preset = Self.presets.first(where: { $0.name == name }) { customPalette = preset.palette }
        choice = name
    }

    private static var pictureFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HomeBackground.jpg")
    }

    // Shrunk while decoding: a 48 MP photo would cost 190 MB of the memory games need.
    func setPicture(_ data: Data) {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2200]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        let image = UIImage(cgImage: cg)
        try? image.jpegData(compressionQuality: 0.85)?.write(to: Self.pictureFile, options: .atomic)
        picture = image
    }

    func removePicture() {
        try? FileManager.default.removeItem(at: Self.pictureFile)
        picture = nil
    }
}

extension View {
    // The theme's gradient (and, in Local Games, the picture) behind a screen. System theme without a picture leaves the
    // stock look alone.
    func themed(picture: Bool = false) -> some View { modifier(Themed(picture: picture)) }
}

private struct Themed: ViewModifier {
    @Environment(Appearance.self) private var look
    @Environment(\.colorScheme) private var scheme
    let picture: Bool

    func body(content: Content) -> some View {
        let image = picture ? look.picture : nil
        let palette = look.palette
        content
            .scrollContentBackground(palette == nil && image == nil ? .automatic : .hidden)
            .background {
                ZStack {
                    if let palette {
                        LinearGradient(colors: palette.background(dark: scheme == .dark), startPoint: .top, endPoint: .bottom)
                    } else if image != nil {
                        Color(.systemBackground)
                    }
                    if let image {
                        Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
                        Color(.systemBackground).opacity(look.dim)   // keeps tile names readable on any picture
                    }
                }
                .ignoresSafeArea()
            }
    }
}
