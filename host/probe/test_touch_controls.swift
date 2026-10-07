// Simulator check for host/TouchControls.swift: touches in, pad values out (what a game reads). Booted simulator:
// SDK=$(xcrun --sdk iphonesimulator --show-sdk-path); T=arm64-apple-ios26.0-simulator
// clang -c -fobjc-arc -target $T -isysroot $SDK host/ShackTouchPad.m -o /tmp/stp.o && swiftc -parse-as-library -target $T -sdk $SDK \
//   -import-objc-header host/ShackTouchPad.h host/TouchControls.swift host/probe/test_touch_controls.swift /tmp/stp.o \
//   -framework GameController -o /tmp/t && xcrun simctl spawn booted /tmp/t
import UIKit
import GameController
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL \(line): \(what)"); exit(1) } }
func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
func at(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }

@main enum TouchControlsCheck {
    @MainActor static func main() {
        var ours: GCController?
        _ = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { n in if ours == nil { ours = n.object as? GCController } }
        ShackTouchPadSetConnected(true)
        guard let pad = ours?.extendedGamepad else { print("FAIL: no pad"); exit(1) }
        let v = TouchControlsView(frame: CGRect(x: 0, y: 0, width: 956, height: 440))
        v.layoutIfNeeded()
        // The layout's centres for a 956 x 440 view (host/TouchControls.swift tables)
        let face = CGPoint(x: 0.84 * 956, y: 0.55 * 440)
        let A = CGPoint(x: face.x, y: face.y + 50), X = CGPoint(x: face.x - 50, y: face.y), Y = CGPoint(x: face.x, y: face.y - 50)
        let left = CGPoint(x: 0.14 * 956, y: 0.55 * 440), right = CGPoint(x: 0.71 * 956, y: 0.80 * 440), dpad = CGPoint(x: 0.29 * 956, y: 0.80 * 440)
        let RT = CGPoint(x: 0.94 * 956, y: 0.10 * 440)

        check(v.point(inside: A, with: nil) && !v.point(inside: CGPoint(x: 478, y: 220), with: nil), "only controls take touches")
        v.begin(1, at: A); spin(); check(pad.buttonA.isPressed, "A pressed")
        v.end(1); spin(); check(!pad.buttonA.isPressed, "A released")

        v.begin(2, at: at(left, 58, 0)); spin(); check(pad.leftThumbstick.xAxis.value == 1 && pad.leftThumbstick.yAxis.value == 0, "stick at ring edge")
        v.move(2, to: at(left, 116, 0)); spin(); check(pad.leftThumbstick.xAxis.value == 1, "stick clamped past the ring")
        v.move(2, to: at(left, 0, -29)); spin(); check(pad.leftThumbstick.xAxis.value == 0 && pad.leftThumbstick.yAxis.value == 0.5, "stick up is +y")
        v.end(2); spin(); check(pad.leftThumbstick.xAxis.value == 0 && pad.leftThumbstick.yAxis.value == 0, "stick recentres")

        v.begin(3, at: at(dpad, -30, -30)); spin(); check(pad.dpad.left.isPressed && pad.dpad.up.isPressed && !pad.dpad.right.isPressed, "d-pad up-left")
        v.move(3, to: at(dpad, 0, 40)); spin(); check(pad.dpad.down.isPressed && !pad.dpad.left.isPressed && !pad.dpad.up.isPressed, "d-pad slides to down")
        v.end(3)

        v.begin(4, at: X); spin(); check(pad.buttonX.isPressed, "X pressed")
        v.move(4, to: Y); spin(); check(!pad.buttonX.isPressed && pad.buttonY.isPressed, "slide X to Y")
        v.end(4); spin(); check(!pad.buttonY.isPressed, "Y released")

        v.begin(5, at: at(left, 0, 58)); v.begin(6, at: RT); v.begin(7, at: at(right, 48, 0)); spin()
        check(pad.leftThumbstick.yAxis.value == -1 && pad.rightTrigger.value == 1 && pad.rightThumbstick.xAxis.value == 1, "three touches at once")
        v.begin(8, at: at(RT, 3, 3)); v.end(6); spin(); check(pad.rightTrigger.isPressed, "a button stays held while any touch holds it")
        v.end(5); v.end(7); v.end(8); spin()
        check(pad.leftThumbstick.yAxis.value == 0 && !pad.rightTrigger.isPressed && pad.rightThumbstick.xAxis.value == 0, "all released")
        v.begin(9, at: CGPoint(x: 478, y: 220)); spin(); check(!pad.buttonA.isPressed && pad.leftThumbstick.xAxis.value == 0, "a touch off the controls does nothing")
        print("touch controls ok")

    }
}
