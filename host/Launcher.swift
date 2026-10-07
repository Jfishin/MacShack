import SwiftUI

// MacShack's first screen: Steam Big Picture, Local Games and Settings over Steam's dark blue, nothing else. A, X and Y
// press them. Only SwiftUI and PadNav here, so host/probe/test_launcher.swift shows it in the simulator;
// LauncherView.swift wires it to MacShack.
struct LauncherScreen: View {
    @Environment(PadNav.self) private var pad
    let steamReady: Bool   // the Steam client is set up on this device (else the first button sets it up)
    var modal = false      // Steam setup covers the screen: no presses here
    let bigPicture: () -> Void
    let localGames: () -> Void
    let settings: () -> Void

    private let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 16) {
            capsule(steamReady ? "Steam Big Picture" : "Set up Steam", symbol: steamReady ? "play.fill" : "arrow.down.circle.fill",
                    key: "a", fill: .steamBlue, text: .black, action: bigPicture)
            capsule("Local Games", symbol: "square.grid.2x2.fill", key: "x", fill: .steamSlate, text: .white, action: localGames)
            Button(action: settings) {
                Image(systemName: "gearshape.fill").font(.headline).foregroundStyle(.white)
                    .frame(width: height, height: height)
                    .background(Circle().fill(Color.steamSlate))
                    .overlay(alignment: .topTrailing) { if pad.active { hint("y").offset(x: 4, y: -4) } }
                    .contentShape(Circle())
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LauncherBackground() }
        .padHandler { press in
            guard !modal else { return false }
            switch press {
            case .a: bigPicture()
            case .x: localGames()
            case .y: settings()
            default: return false
            }
            return true
        }
    }

    private func capsule(_ title: String, symbol: String, key: String, fill: Color, text: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
                if pad.active { hint(key) }
            }
            .font(.headline).foregroundStyle(text)
            .padding(.horizontal, 26).frame(height: height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
    }

    private func hint(_ key: String) -> some View { Image(systemName: "\(key).circle.fill").font(.subheadline).opacity(0.8) }
}

// Steam's dark blue with a soft glow of its light blue from the top left: the first screen, and behind Steam setup.
struct LauncherBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(rgb: 0x171a21), Color(rgb: 0x1b2838)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.steamBlue.opacity(0.22), .clear], center: .topLeading, startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(rgb: UInt32) { self.init(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255) }
    static let steamBlue = Color(rgb: 0x66c0f4), steamSlate = Color(rgb: 0x2a475e)
}
