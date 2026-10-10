import GameController
import SwiftUI
import UIKit

// MacShack Play's island menu over a Mac game, as MacShack's (host/GameOverlay.swift): a button over the Dynamic
// Island's spot opens a Liquid Glass panel (Keyboard, Controller, Quit); the on-screen controller shows while no
// physical pad is connected. ponytail: frame rate and resolution stay in MacShack's panel until game settings live in
// the App Group; then one overlay serves both apps.
@Observable
@MainActor
final class PlayOverlayModel {
    var name = ""
    var showPanel = false
    var quitting = false
    var controllerWanted = !UserDefaults.standard.bool(forKey: "touchControlsHidden")
    var physicalPad = false
    var islandLeft = true
    var size = CGSize.zero
    var islandInset: CGFloat = 62
    var islandRect: CGRect {   // as GameOverlayModel's: the island's spot, sideways, with a margin
        let width = max(60, islandInset + 6), height: CGFloat = 125 + 50
        return CGRect(x: islandLeft ? 0 : size.width - width, y: (size.height - height) / 2, width: width, height: height)
    }
    var controllerShown: Bool { controllerWanted && !physicalPad && !showPanel }

    func quit() { quitting = true; PlayRequestGameQuit() }
    func toggleController() {
        controllerWanted.toggle()
        UserDefaults.standard.set(!controllerWanted, forKey: "touchControlsHidden")
        showPanel = false
        updatePads()
    }
    func updatePads() {
        physicalPad = GCController.controllers().contains { $0.extendedGamepad != nil && String(describing: type(of: $0)) != "ShackTouchPadController" }
        ShackTouchPadSetConnected(controllerWanted && !physicalPad)
    }
}

private final class PlayPassthroughWindow: UIWindow {
    var model: PlayOverlayModel?
    let pad = TouchControlsView()
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let model else { return nil }
        if !pad.isHidden, !model.islandRect.contains(point), pad.point(inside: convert(point, to: pad), with: event) { return pad }
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return model.showPanel || model.islandRect.contains(point) ? hit : nil
    }
    func trackPad() {
        guard let model else { return }
        withObservationTracking { pad.isHidden = !model.controllerShown }
            onChange: { Task { @MainActor [weak self] in self?.trackPad() } }
    }
}

private final class PlayOverlayController: UIHostingController<PlayOverlayView> {
    let model: PlayOverlayModel
    init(model: PlayOverlayModel) {
        self.model = model
        super.init(rootView: PlayOverlayView(model: model))
        view.backgroundColor = .clear
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        model.size = view.bounds.size
        model.islandLeft = view.window?.windowScene?.effectiveGeometry.interfaceOrientation != .landscapeLeft
        if let insets = view.window?.safeAreaInsets { model.islandInset = model.islandLeft ? insets.left : insets.right }
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}

struct PlayOverlayView: View {
    @Bindable var model: PlayOverlayModel
    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: model.islandRect.width, height: model.islandRect.height)
                .position(x: model.islandRect.midX, y: model.islandRect.midY)
                .onTapGesture { model.showPanel = true }
                .onLongPressGesture(minimumDuration: 0.3) { model.showPanel = true }
            if model.showPanel {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                        .onTapGesture { if !model.quitting { model.showPanel = false } }
                    VStack(spacing: 16) {
                        Text(model.quitting ? "Saving and quitting…" : model.name).font(.title3.bold())
                        if model.quitting {
                            ProgressView()
                        } else {
                            HStack(spacing: 12) {
                                Button { model.showPanel = false; PlayToggleKeyboard() } label: { Label("Keyboard", systemImage: "keyboard") }
                                    .buttonStyle(.glass)
                                Button { model.toggleController() } label: {
                                    Label(model.controllerWanted ? "Hide Controller" : "Controller", systemImage: "gamecontroller")
                                }.buttonStyle(.glass)
                                Button(role: .destructive) { model.quit() } label: { Label("Quit", systemImage: "xmark.circle") }
                                    .buttonStyle(.glassProminent)
                            }
                            Button("Back to game") { model.showPanel = false }.buttonStyle(.glass)
                        }
                    }
                    .padding(28)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

@objc final class PlayOverlay: NSObject {
    @MainActor private static var window: UIWindow?
    // Over the game's window (the AppKit shim fills Play's own), for the whole run; before the game looks for pads.
    @MainActor @objc static func show(name: String) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let model = PlayOverlayModel()
        model.name = name
        let w = PlayPassthroughWindow(windowScene: scene)
        w.model = model
        w.windowLevel = .normal + 1
        w.backgroundColor = .clear
        w.rootViewController = PlayOverlayController(model: model)
        w.isHidden = false   // shown, never key: the game keeps keyboard and controller focus
        w.pad.frame = w.bounds
        w.pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.addSubview(w.pad)
        w.trackPad()
        window = w
        model.updatePads()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { model.updatePads() } }
        }
    }
}
