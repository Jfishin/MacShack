import SwiftUI
import UIKit

// MacShack's button over the Dynamic Island while a game runs. The island itself cannot be a button for the app in
// front (iOS hides an app's own Live Activity), so a transparent window above the game claims a small area over the
// island's spot and passes every other touch through to the game. A tap or short hold opens a Liquid Glass panel to quit, bring up the
// keyboard or show the on-screen controller (whose controls are the only other areas the window claims).
@Observable
@MainActor
final class GameOverlayModel {
    var gameName = ""
    var splashGame: URL?   // the launch splash stays over the game until it has drawn for a moment
    @ObservationIgnored var splashShownAt = Date.now
    var showPanel = false
    var quitting = false
    var showForceQuit = false
    var islandLeft = true
    var touchControls = UserDefaults.standard.bool(forKey: "touchControls")   // the on-screen controller, from the panel
    var size = CGSize.zero
    var islandInset: CGFloat = 62   // the safe area on the island's side (landscape)

    // The island's spot, sideways: its far edge sits 11 pt inside the safe area (measured: 14 pt on a 62 pt
    // inset, 11 on 59), its length is 125 pt. The button covers it from the screen edge with a margin all round.
    var islandRect: CGRect {
        let width = max(60, islandInset + 6), height: CGFloat = 125 + 50
        return CGRect(x: islandLeft ? 0 : size.width - width, y: (size.height - height) / 2, width: width, height: height)
    }

    // Frame rate and resolution from the panel: the running game's own settings (the keys of Local Games' tiles), or Big
    // Picture's while the Steam client runs no game. The frame rate changes at once; resolution at the next start.
    @ObservationIgnored var steam = false
    @ObservationIgnored var gameKey: String?   // MacShack's game: Documents/Games/<Name>.app
    @ObservationIgnored var translate = false
    var cap = 0
    var scale = 0.0
    var settingsName: String? { steam ? ShackSteamClientGameName() : gameKey }   // nil: Big Picture
    var panelTitle: String { steam ? ShackSteamClientGameName() ?? "Steam" : gameName }

    func openPanel() {
        if let name = settingsName {
            cap = Int(ShackGameFrameCap(name, translate))
            scale = ShackGameRenderScale(name, translate)
        } else {
            cap = Int(ShackSteamUIFrameCap())
            scale = ShackSteamUIRenderScale()
        }
        if scale <= 0 || scale > UIScreen.main.scale { scale = UIScreen.main.scale }
        showPanel = true
    }
    func nextCap() {
        let choices = [displayHz / 2, displayHz / 3, displayHz / 4, 0]   // 120 Hz: 60, 40, 30, uncapped
        cap = choices[((choices.firstIndex(of: cap) ?? -1) + 1) % choices.count]
        UserDefaults.standard.set(cap, forKey: settingsName.map { "fpsCap.\($0)" } ?? "steamUI.fpsCap")
        ShackMetalSetFrameCap(Int32(cap))
    }
    func nextScale() {
        let choices = renderScales.filter { $0 <= UIScreen.main.scale }
        scale = choices[((choices.firstIndex(of: scale) ?? -1) + 1) % choices.count]
        UserDefaults.standard.set(scale, forKey: settingsName.map { "renderScale.\($0)" } ?? "steamUI.renderScale")
    }

    func quit() {
        quitting = true
        ShackAppKitRequestQuit()
        Task {
            try? await Task.sleep(for: .seconds(10))
            if quitting { showForceQuit = true }   // the game did not end: offer the old way out
        }
    }
    func forceQuit() { ShackExitProcess(0) }

    func toggleTouchControls() {
        touchControls.toggle()
        UserDefaults.standard.set(touchControls, forKey: "touchControls")
        ShackTouchPadSetConnected(touchControls)
        showPanel = false
    }

    // The game drew its first frame: keep the splash at least 6 s in all, and 2.5 s past this, then fade it out.
    func firstFrame() {
        let wait = max(2.5, 6 - Date.now.timeIntervalSince(splashShownAt))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            splashGame = nil
        }
    }
}

private final class PassthroughWindow: UIWindow {
    var model: GameOverlayModel?
    // The on-screen controller is plain UIKit above the SwiftUI layer: inside SwiftUI, UIKit's repeated hit tests of one
    // touch got the hosting view instead of the controls (simulator, 2026-09-30). Asked first; the island still wins.
    let pad = TouchControlsView()
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let model else { return nil }
        if !pad.isHidden, !model.islandRect.contains(point), pad.point(inside: convert(point, to: pad), with: event) { return pad }
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return model.splashGame != nil || model.showPanel || model.islandRect.contains(point) ? hit : nil
    }
    // Shown while wanted and neither the launch splash nor the panel is up.
    func trackPad() {
        guard let model else { return }
        withObservationTracking { pad.isHidden = !(model.touchControls && model.splashGame == nil && !model.showPanel) }
            onChange: { Task { @MainActor [weak self] in self?.trackPad() } }
    }
}

private final class OverlayController: UIHostingController<AnyView> {
    let model: GameOverlayModel
    init(model: GameOverlayModel, app: AppModel) {
        self.model = model
        super.init(rootView: AnyView(GameOverlayView(model: model).environment(app)))   // SplashView reads launch status
        view.backgroundColor = .clear
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        model.size = view.bounds.size
        // Landscape-right puts the top of the phone, and the island, on the left.
        model.islandLeft = view.window?.windowScene?.effectiveGeometry.interfaceOrientation != .landscapeLeft
        if let insets = view.window?.safeAreaInsets { model.islandInset = model.islandLeft ? insets.left : insets.right }
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}

struct GameOverlayView: View {
    @Bindable var model: GameOverlayModel

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)   // hit-testable but invisible
                .frame(width: model.islandRect.width, height: model.islandRect.height)
                .position(x: model.islandRect.midX, y: model.islandRect.midY)
                .onTapGesture { model.openPanel() }   // a tap or a hold: the island's area is the screen edge's middle,
                .onLongPressGesture(minimumDuration: 0.3) { model.openPanel() }   // where a game rarely wants touches
            if model.showPanel { panel }
            if let game = model.splashGame { SplashView(game: game).transition(.opacity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: model.splashGame)
    }

    private var panel: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { if !model.quitting { model.showPanel = false } }
            VStack(spacing: 16) {
                Text(model.quitting ? "Saving and quitting…" : model.panelTitle).font(.title3.bold())
                if model.quitting {
                    ProgressView()
                    if model.showForceQuit {
                        Text("The game has not closed.").font(.footnote).foregroundStyle(.secondary)
                        Button("Force Quit", role: .destructive) { model.forceQuit() }.buttonStyle(.glassProminent)
                    }
                } else {
                    HStack(spacing: 12) {
                        Button { model.showPanel = false; ShackAppKitToggleKeyboard() } label: {
                            Label("Keyboard", systemImage: "keyboard")
                        }.buttonStyle(.glass)
                        Button { model.toggleTouchControls() } label: {
                            Label(model.touchControls ? "Hide Controller" : "Controller", systemImage: "gamecontroller")
                        }.buttonStyle(.glass)
                        Button(role: .destructive) { model.quit() } label: {
                            Label("Quit", systemImage: "xmark.circle")
                        }.buttonStyle(.glassProminent)
                    }
                    HStack(spacing: 12) {
                        Button { model.nextCap() } label: {
                            Label(model.cap == 0 ? "Uncapped" : "\(model.cap) fps", systemImage: "speedometer")
                        }.buttonStyle(.glass)
                        Button { model.nextScale() } label: {
                            Label(scaleName(model.scale), systemImage: "aspectratio")
                        }.buttonStyle(.glass)
                    }
                    Text(model.settingsName == nil ? "Resolution changes when Steam starts again." : "Resolution changes at the game's next launch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Back to game") { model.showPanel = false }.buttonStyle(.glass)
                }
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }
}

@MainActor
enum GameOverlay {
    private static var window: UIWindow?
    private static var firstFrameObserver: NSObjectProtocol?
    private static var steamGameObserver: NSObjectProtocol?

    // Shown at launch with the splash on top (a game; the Steam client draws its own, and the splash comes up for a game
    // Steam starts: ShackSteamClient.m); the island button stays for the whole run.
    static func show(game: URL?, name: String? = nil, app: AppModel) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let model = GameOverlayModel()
        model.gameName = name ?? game.map(app.displayName) ?? ""
        model.steam = game == nil
        model.gameKey = game?.deletingPathExtension().lastPathComponent
        model.translate = game.map { ShackInstaller.translates(atAppPath: $0.path) } ?? false
        model.splashGame = game
        firstFrameObserver = NotificationCenter.default.addObserver(forName: Notification.Name("ShackGameFirstFrame"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { model.firstFrame() }
        }
        steamGameObserver = NotificationCenter.default.addObserver(forName: Notification.Name("ShackSteamGameStarting"), object: nil, queue: .main) { note in
            let path = note.object as? String
            MainActor.assumeIsolated {
                model.splashShownAt = .now
                model.splashGame = path.map { URL(fileURLWithPath: $0) }
            }
        }
        let w = PassthroughWindow(windowScene: scene)
        w.model = model
        w.windowLevel = .normal + 1   // above the game's window, which the AppKit shim fills
        w.backgroundColor = .clear
        w.rootViewController = OverlayController(model: model, app: app)
        w.isHidden = false            // shown, never key: the game keeps keyboard and controller focus
        w.pad.frame = w.bounds
        w.pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.addSubview(w.pad)           // above the SwiftUI root view
        w.trackPad()
        window = w
        if model.touchControls { ShackTouchPadSetConnected(true) }   // before the game looks for pads, like a paired one
    }

    static func hide() {
        ShackTouchPadSetConnected(false)
        for observer in [firstFrameObserver, steamGameObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        firstFrameObserver = nil
        steamGameObserver = nil
        window?.isHidden = true
        window = nil
    }
}
