import UIKit

// The on-screen controller: a full Xbox layout over the running game (GameOverlay shows it from the island panel).
// Every touch owns one control: a stick keeps its touch past the ring, a touch on the face buttons slides between
// them, any other button stays held until its touch lifts. The whole pad is recomputed from the live touches on every
// event and handed to ShackTouchPad (which drops unchanged values), so no press can stick. Only the controls take
// touches; every other touch reaches the game.
// ponytail: one fixed landscape layout; moving, resizing and per-game layouts come later.
final class TouchControlsView: UIView {
    private enum Hold { case button(ShackPadButton), face, stick(Int), dpad }

    // Centres are fractions of the view, sizes points. The island strip (60 x 160 at a short edge) stays clear.
    private static let pills: [(ShackPadButton, CGPoint, CGSize, String)] = [
        (.LT, CGPoint(x: 0.06, y: 0.10), CGSize(width: 64, height: 32), "LT"),
        (.LB, CGPoint(x: 0.16, y: 0.10), CGSize(width: 64, height: 32), "LB"),
        (.view, CGPoint(x: 0.42, y: 0.10), CGSize(width: 44, height: 30), "rectangle.on.rectangle"),
        (.menu, CGPoint(x: 0.58, y: 0.10), CGSize(width: 44, height: 30), "line.3.horizontal"),
        (.RB, CGPoint(x: 0.84, y: 0.10), CGSize(width: 64, height: 32), "RB"),
        (.RT, CGPoint(x: 0.94, y: 0.10), CGSize(width: 64, height: 32), "RT"),
    ]
    private static let faceCentre = CGPoint(x: 0.84, y: 0.55), faceSize: CGFloat = 50, faceSpacing: CGFloat = 50
    private static let faces: [(ShackPadButton, CGVector, String, UIColor)] = [
        (.A, CGVector(dx: 0, dy: 1), "A", .systemGreen), (.B, CGVector(dx: 1, dy: 0), "B", .systemRed),
        (.X, CGVector(dx: -1, dy: 0), "X", .systemBlue), (.Y, CGVector(dx: 0, dy: -1), "Y", .systemYellow),
    ]
    private static let sticks: [(centre: CGPoint, radius: CGFloat, click: ShackPadButton, label: String)] = [
        (CGPoint(x: 0.14, y: 0.55), 58, .L3, "L3"), (CGPoint(x: 0.71, y: 0.80), 48, .R3, "R3"),
    ]
    private static let dpadCentre = CGPoint(x: 0.29, y: 0.80), dpadSize: CGFloat = 112, clickSize: CGFloat = 36
    private static let armDirections = [CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0)]

    private var holds: [AnyHashable: (hold: Hold, at: CGPoint)] = [:]
    private var glyphs: [ShackPadButton: Glyph] = [:]
    private var rings: [Glyph] = [], knobs: [Glyph] = [], arms: [Glyph] = []   // arms: up, down, left, right

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for (b, _, size, label) in Self.pills { glyphs[b] = add(Glyph(size: size, label: label, round: false)) }
        for (b, _, label, tint) in Self.faces { glyphs[b] = add(Glyph(size: CGSize(width: Self.faceSize, height: Self.faceSize), label: label, tint: tint)) }
        for s in Self.sticks {
            rings.append(add(Glyph(size: CGSize(width: s.radius * 2, height: s.radius * 2), label: "")))
            knobs.append(add(Glyph(size: CGSize(width: s.radius, height: s.radius), label: "")))
            glyphs[s.click] = add(Glyph(size: CGSize(width: Self.clickSize, height: Self.clickSize), label: s.label))
        }
        for dir in ["up", "down", "left", "right"] {
            arms.append(add(Glyph(size: CGSize(width: Self.dpadSize / 3, height: Self.dpadSize / 3), label: "arrowtriangle.\(dir).fill", round: false)))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ g: Glyph) -> Glyph { addSubview(g); return g }
    private func at(_ f: CGPoint) -> CGPoint { CGPoint(x: bounds.width * f.x, y: bounds.height * f.y) }
    private func faceCentre(_ v: CGVector) -> CGPoint {
        let c = at(Self.faceCentre); return CGPoint(x: c.x + v.dx * Self.faceSpacing, y: c.y + v.dy * Self.faceSpacing)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (b, f, _, _) in Self.pills { glyphs[b]?.center = at(f) }
        for (b, v, _, _) in Self.faces { glyphs[b]?.center = faceCentre(v) }
        for (i, s) in Self.sticks.enumerated() {
            let c = at(s.centre)
            rings[i].center = c
            glyphs[s.click]?.center = CGPoint(x: c.x, y: c.y - s.radius - Self.clickSize / 2 - 8)
        }
        let d = at(Self.dpadCentre), step = Self.dpadSize / 3
        for (arm, v) in zip(arms, Self.armDirections) { arm.center = CGPoint(x: d.x + v.dx * step, y: d.y + v.dy * step) }
        sync()
    }

    // The control a new touch at p takes: small buttons first, then the face group, the d-pad and the sticks.
    private func control(at p: CGPoint) -> Hold? {
        let isFace = Set(Self.faces.map(\.0))
        if let b = glyphs.first(where: { !isFace.contains($0.key) && $0.value.frame.insetBy(dx: -10, dy: -10).contains(p) })?.key { return .button(b) }
        if p.distance(to: at(Self.faceCentre)) <= Self.faceSpacing + Self.faceSize / 2 + 12 { return .face }
        if p.distance(to: at(Self.dpadCentre)) <= Self.dpadSize / 2 + 12 { return .dpad }
        if let i = Self.sticks.indices.first(where: { p.distance(to: at(Self.sticks[$0].centre)) <= Self.sticks[$0].radius * 1.4 }) { return .stick(i) }
        return nil
    }
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool { control(at: p) != nil }

    private func faceButton(at p: CGPoint) -> ShackPadButton? {
        Self.faces.map { ($0.0, p.distance(to: faceCentre($0.1))) }.filter { $0.1 <= Self.faceSize * 0.8 }.min { $0.1 < $1.1 }?.0
    }
    private func stickValue(_ i: Int, _ p: CGPoint) -> CGVector {
        let c = at(Self.sticks[i].centre), r = Self.sticks[i].radius
        let v = CGVector(dx: (p.x - c.x) / r, dy: (c.y - p.y) / r)   // pads report up as +y
        let len = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return len > 1 ? CGVector(dx: v.dx / len, dy: v.dy / len) : v
    }
    // Eight directions: a component counts past sin 22.5° (0.38); a small centre dead zone.
    private func dpadValue(_ p: CGPoint) -> CGVector {
        let c = at(Self.dpadCentre), dx = p.x - c.x, dy = c.y - p.y, len = (dx * dx + dy * dy).squareRoot()
        guard len > Self.dpadSize * 0.12 else { return .zero }
        func axis(_ v: CGFloat) -> CGFloat { abs(v / len) > 0.38 ? (v > 0 ? 1 : -1) : 0 }
        return CGVector(dx: axis(dx), dy: axis(dy))
    }

    // Touch entry points (UIKit's touches, and the simulator check).
    func begin(_ key: AnyHashable, at p: CGPoint) { if let h = control(at: p) { holds[key] = (h, p) }; sync() }
    func move(_ key: AnyHashable, to p: CGPoint) { holds[key]?.at = p; sync() }
    func end(_ key: AnyHashable) { holds[key] = nil; sync() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { begin(ObjectIdentifier(t), at: t.location(in: self)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { holds[ObjectIdentifier(t)]?.at = t.location(in: self) }
        sync()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { end(ObjectIdentifier(t)) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { for t in touches { end(ObjectIdentifier(t)) } }
    override var isHidden: Bool { didSet { if isHidden { holds = [:]; sync() } } }   // hidden (panel open): nothing stays pressed
    override func willMove(toWindow window: UIWindow?) { if window == nil { holds = [:]; sync() } }

    // The pad from the live touches, sent whole, and drawn.
    private func sync() {
        ShackTouchPadSetTouching(!holds.isEmpty)
        var pressed = Set<ShackPadButton>(), sticks = [CGVector.zero, .zero], dpad = CGVector.zero
        for (hold, p) in holds.values {
            switch hold {
            case .button(let b): pressed.insert(b)
            case .face: if let b = faceButton(at: p) { pressed.insert(b) }
            case .stick(let i): sticks[i] = stickValue(i, p)
            case .dpad: dpad = dpadValue(p)
            }
        }
        for (b, g) in glyphs { ShackTouchPadButton(b, pressed.contains(b)); g.pressed = pressed.contains(b) }
        for i in sticks.indices {
            ShackTouchPadStick(i, Float(sticks[i].dx), Float(sticks[i].dy))
            let c = at(Self.sticks[i].centre), r = Self.sticks[i].radius
            knobs[i].center = CGPoint(x: c.x + sticks[i].dx * r, y: c.y - sticks[i].dy * r)
            knobs[i].pressed = sticks[i] != .zero
        }
        ShackTouchPadDpad(Float(dpad.dx), Float(dpad.dy))
        for (arm, on) in zip(arms, [dpad.dy > 0, dpad.dy < 0, dpad.dx < 0, dpad.dx > 0]) { arm.pressed = on }
    }
}

// One drawn control: a translucent circle or rounded pill with a letter or an SF Symbol (a name with a dot).
private final class Glyph: UIView {
    var pressed = false { didSet { if pressed != oldValue { backgroundColor = Self.fill(pressed) } } }
    private static func fill(_ on: Bool) -> UIColor { UIColor.white.withAlphaComponent(on ? 0.45 : 0.14) }

    init(size: CGSize, label: String, round: Bool = true, tint: UIColor = .white) {
        super.init(frame: CGRect(origin: .zero, size: size))
        isUserInteractionEnabled = false
        backgroundColor = Self.fill(false)
        let side = min(size.width, size.height)
        layer.cornerRadius = round ? side / 2 : side * 0.35
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        if label.contains("."), let image = UIImage(systemName: label) {
            let icon = UIImageView(image: image)
            icon.tintColor = tint.withAlphaComponent(0.85)
            icon.contentMode = .scaleAspectFit
            icon.frame = bounds.insetBy(dx: side * 0.28, dy: side * 0.28)
            addSubview(icon)
        } else if !label.isEmpty {
            let text = UILabel(frame: bounds)
            text.text = label
            text.textAlignment = .center
            text.font = .systemFont(ofSize: side * 0.42, weight: .bold)
            text.textColor = tint.withAlphaComponent(0.9)
            addSubview(text)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
