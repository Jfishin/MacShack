import SwiftUI
import GameController

// Game controller navigation for MacShack's own screens. Polled at 60 Hz, as ShackHID polls in games: a
// valueChangedHandler would take the one handler slot a native game may set. Visible views push handlers
// (`.padHandler`); the newest gets a press first (a sheet over its tab, a tab over the tab bar).
@Observable @MainActor
final class PadNav {
    enum Press { case up, down, left, right, a, b, x, y, l1, r1 }

    var active = false            // a pad was used: tiles show a focus ring
    @ObservationIgnored var suspended: () -> Bool = { false }   // a game is running
    @ObservationIgnored private var handlers: [(id: UUID, fn: (Press) -> Bool)] = []
    @ObservationIgnored private var held: Set<Press> = []
    @ObservationIgnored private var repeatAt: [Press: TimeInterval] = [:]
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)   // keeps polling while a scroll view tracks
        timer = t
    }

    func push(_ id: UUID, _ fn: @escaping (Press) -> Bool) { handlers.removeAll { $0.id == id }; handlers.append((id, fn)) }
    func remove(_ id: UUID) { handlers.removeAll { $0.id == id } }

    private func poll() {
        if suspended() { timer?.fireDate = Date(timeIntervalSinceNow: 1); held = []; return }   // a game has the pad: once a second, not 60 times
        guard let pad = GCController.current?.extendedGamepad ?? GCController.controllers().first?.extendedGamepad
        else { held = []; return }
        let stick = pad.leftThumbstick
        var down: Set<Press> = []
        if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { down.insert(.up) }
        if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { down.insert(.down) }
        if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { down.insert(.left) }
        if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { down.insert(.right) }
        if pad.buttonA.isPressed { down.insert(.a) }
        if pad.buttonB.isPressed { down.insert(.b) }
        if pad.buttonX.isPressed { down.insert(.x) }
        if pad.buttonY.isPressed { down.insert(.y) }
        if pad.leftShoulder.isPressed { down.insert(.l1) }
        if pad.rightShoulder.isPressed { down.insert(.r1) }
        let now = ProcessInfo.processInfo.systemUptime
        for p in down {
            if !held.contains(p) { fire(p); repeatAt[p] = now + 0.4 }   // new press
            else if [.up, .down, .left, .right].contains(p), let at = repeatAt[p], now >= at { fire(p); repeatAt[p] = now + 0.11 }
        }
        held = down
    }

    private func fire(_ p: Press) {
        if !active { active = true; return }   // the first press only shows where the focus is
        for h in handlers.reversed() where h.fn(p) { return }
    }
}

extension View {
    // Handles pad presses while this view is on screen; return true when the press was used.
    func padHandler(_ fn: @escaping (PadNav.Press) -> Bool) -> some View { modifier(PadHandlerModifier(fn: fn)) }
}

private struct PadHandlerModifier: ViewModifier {
    @Environment(PadNav.self) private var pad
    @State private var id = UUID()
    let fn: (PadNav.Press) -> Bool
    func body(content: Content) -> some View {
        content.onAppear { pad.push(id, fn) }.onDisappear { pad.remove(id) }
    }
}

// Moves a grid selection: left/right by one, up/down by a row. Returns the new index, or nil at an edge.
func gridMove(_ p: PadNav.Press, from i: Int, count: Int, columns: Int) -> Int? {
    let j: Int
    switch p {
    case .left: j = i - 1
    case .right: j = i + 1
    case .up: j = i - columns
    case .down: if i / columns == (count - 1) / columns { return nil }; j = min(i + columns, count - 1)
    default: return nil
    }
    return j >= 0 && j < count && j != i ? j : nil
}

// Columns an adaptive grid of HomeView.columns lays out across `width` (SwiftUI fits as many minimum-width items
// as the spacing allows).
func gridColumns(width: CGFloat) -> Int { max(1, Int((width + 16) / (100 + 16))) }
