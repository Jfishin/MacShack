import SwiftUI
import UIKit

// Where the in-game menu opens: the island on an iPhone, the side edge's middle on an iPad (hints here and in Settings).
enum MenuSpot {
    static var text: String { UIDevice.current.userInterfaceIdiom == .pad ? "the middle of the screen's side edge" : "the Dynamic Island" }
}

// Shown from the tap on a game until the game's own window takes over the screen (the AppKit shim replaces MacShack's
// root view controller, which removes this). Teaches the one thing a player needs: the MacShack menu lives on the
// Dynamic Island, or the middle of the side edge on iPad (GameOverlay.swift). Tips rotate underneath, Big Picture style.
struct SplashView: View {
    let game: URL
    let name: String
    var status = ""   // under the spinner; empty: "Starting <name>…"
    @State private var art: UIImage?
    @State private var tip = 0

    static let tips = [
        "Hold \(MenuSpot.text) any time for the MacShack menu. Quit there so the game can save.",
        "Need to type a name? Hold \(MenuSpot.text), then Keyboard.",
        "Unity and Intel games need JIT once per launch: keep the device unlocked and LocalDevVPN on.",
        "Controllers work in most games: connect one in Settings > Bluetooth before you start.",
        "Hold a game in Local Games to set its own frame cap or prepare it again.",
    ]

    private var header: some View {
        HStack(spacing: 14) {
            if let art {
                Image(uiImage: art).resizable().scaledToFill().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            Text(name).font(.title.bold())
        }
    }
    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hold \(MenuSpot.text) during the game for the MacShack menu: keyboard and quit.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
        }
    }
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().tint(.white)
            Text(status.isEmpty ? "Starting \(name)…" : status).font(.footnote)
        }
    }
    private var tipView: some View {
        Label(Self.tips[tip], systemImage: "lightbulb.fill")
            .font(.footnote).padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .contentTransition(.opacity)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let art {
                Image(uiImage: art).resizable().scaledToFill().blur(radius: 40).opacity(0.55).ignoresSafeArea()
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // Landscape only, like the overlay above the game: diagram left, game and status right, so nothing is
            // pushed off the top of a 440 pt tall screen.
            HStack(spacing: 36) {
                DeviceDiagram().frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 14) { header; hints; statusRow; tipView }
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .foregroundStyle(.white)
        }
        .task {
            art = await Artwork.icon(forApp: game)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeInOut(duration: 0.4)) { tip = (tip + 1) % Self.tips.count }
            }
        }
    }
}

// A landscape iPhone outline (island on the left, where GameOverlay puts the menu button; MacShack is landscape
// only, so no turn) whose island pulses under a tapping hand; on an iPad, a 4:3 outline with the spot in the middle of
// that side edge. Core Animation, not SwiftUI: the render server keeps it moving while the main thread is busy loading
// the game's libraries.
private struct DeviceDiagram: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 180))
        let phone = CALayer()
        phone.bounds = pad ? CGRect(x: 0, y: 0, width: 150, height: 112) : CGRect(x: 0, y: 0, width: 156, height: 74)
        phone.position = CGPoint(x: 90, y: 90)
        view.layer.addSublayer(phone)

        let outline = CAShapeLayer()
        outline.path = UIBezierPath(roundedRect: phone.bounds.insetBy(dx: 1.5, dy: 1.5), cornerRadius: pad ? 12 : 20).cgPath
        outline.fillColor = nil
        outline.strokeColor = UIColor.white.cgColor
        outline.lineWidth = 3
        phone.addSublayer(outline)

        let islandFrame = pad ? CGRect(x: 6, y: 56 - 14, width: 5, height: 28)   // the side edge's middle
                              : CGRect(x: 14 - 3.5, y: 37 - 12, width: 7, height: 24)   // 64 pt left of centre
        let island = CALayer()
        island.frame = islandFrame
        island.cornerRadius = 3.5
        island.backgroundColor = UIColor.white.cgColor
        phone.addSublayer(island)

        let ring = CAShapeLayer()
        ring.bounds = CGRect(origin: .zero, size: islandFrame.size)
        ring.position = CGPoint(x: islandFrame.midX, y: islandFrame.midY)
        ring.path = UIBezierPath(roundedRect: ring.bounds, cornerRadius: 3.5).cgPath
        ring.fillColor = nil
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        phone.addSublayer(ring)

        let hand = CALayer()
        let symbol = UIImage(systemName: "hand.tap.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        hand.contents = symbol?.cgImage
        hand.contentsScale = UIScreen.main.scale
        hand.bounds = CGRect(origin: .zero, size: symbol?.size ?? CGSize(width: 30, height: 30))
        hand.position = CGPoint(x: islandFrame.midX + 20, y: islandFrame.midY + 34)
        hand.opacity = 0
        phone.addSublayer(hand)

        // One 3.4 s loop: hold, pulse the island with the hand, hold.
        let cycle: CFTimeInterval = 3.4
        func loop(_ path: String, _ values: [Any], _ times: [NSNumber]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values; a.keyTimes = times; a.duration = cycle; a.repeatCount = .infinity
            a.calculationMode = .linear
            a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
            return a
        }
        ring.add(loop("transform.scale", [1, 1, 1, 2.6, 2.6], [0, 0.5, 0.55, 0.85, 1]), forKey: "pulse")
        ring.add(loop("opacity", [0, 0, 0.9, 0, 0], [0, 0.5, 0.55, 0.85, 1]), forKey: "fade")
        hand.add(loop("opacity", [0, 0, 1, 1, 0], [0, 0.48, 0.55, 0.9, 1]), forKey: "tap")
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
