// Mac check: swiftc -parse-as-library host/AutoConfig.swift host/probe/test_auto_config.swift -o /tmp/t && /tmp/t
import Foundation

@main struct TestAutoConfig {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
    static func app(_ root: URL, _ name: String, id: String, unity: Bool = false) -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contents.appendingPathComponent(unity ? "Resources/Data" : "MacOS"), withIntermediateDirectories: true)
        (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        return app
    }
    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("autoconfig-\(UUID().uuidString)")
        let store = root.appendingPathComponent("GameConfigs")
        // Rules: the Fountains log lines, verbatim.
        let gl = "ERROR: Could not initialize native OpenGL.\n2026 [ShackAppKit] NSAlert: Unable to initialize OpenGL video driver — (null) [OK]"
        let ak = "thread '<unnamed>' panicked at /Users/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/accesskit_macos-0.22.0/src/adapter.rs:96:43:"
        check(AutoConfig.diagnose(log: gl, current: []).map(\.args) == [["--rendering-driver", "opengl3_angle"]], "OpenGL rule")
        check(AutoConfig.diagnose(log: ak, current: []).map(\.args) == [["--accessibility", "disabled"]], "AccessKit rule")
        let unity = "Forcing GfxDevice: Metal\nForced GfxDevice 'Metal' was not built from editor, shaders will not be available"
        check(AutoConfig.diagnose(log: unity, current: ["-stdout"]).map(\.args) == [["-force-glcore"]], "Unity GL-only rule")
        check(AutoConfig.diagnose(log: "Godot Engine v4.5.1 all fine", current: []).isEmpty, "clean log: no rule")
        check(AutoConfig.diagnose(log: gl, current: ["--rendering-driver", "opengl3_angle"]).isEmpty, "applied rule not offered again")

        // Seeding: known fix into a missing .args; remembered beats known; custom never rewritten.
        let fountains = app(root, "Fountains", id: "com.johnpywell.fountains")
        let args = root.appendingPathComponent("Fountains.args")
        AutoConfig.prepare(game: fountains, store: store)
        check(text(args) == "--rendering-driver\nopengl3_angle\n--accessibility\ndisabled\n", "known fix seeded")
        check(text(store.appendingPathComponent("com.johnpywell.fountains.args")) == text(args), "seeded custom config remembered")
        try! "--custom\n".write(to: args, atomically: true, encoding: .utf8)
        AutoConfig.prepare(game: fountains, store: store)
        check(text(args) == "--custom\n", "custom .args never rewritten")
        check(text(store.appendingPathComponent("com.johnpywell.fountains.args")) == "--custom\n", "custom .args remembered")
        try! FileManager.default.removeItem(at: args)   // Delete, then re-download
        AutoConfig.prepare(game: fountains, store: store)
        check(text(args) == "--custom\n", "remembered config restored after delete")

        // A default .args counts as unconfigured (Parking Garage held the Unity flags).
        let garage = app(root, "Garage", id: "com.walaber.garagerally", unity: true)
        let garageArgs = root.appendingPathComponent("Garage.args")
        try! "-stdout\n-FullStdOutLogOutput\n-nosplash\n".write(to: garageArgs, atomically: true, encoding: .utf8)
        AutoConfig.prepare(game: garage, store: store)
        check(text(garageArgs) == "--rendering-method\nforward_plus\n", "default .args replaced by known fix")

        // Unknown game with defaults: untouched, nothing remembered.
        let plain = app(root, "Plain", id: "com.example.plain")
        AutoConfig.prepare(game: plain, store: store)
        check(text(root.appendingPathComponent("Plain.args")) == nil, "no config: ShackLoader writes defaults")
        check(text(store.appendingPathComponent("com.example.plain.args")) == nil, "defaults not remembered")

        // Apply appends the rule's lines.
        AutoConfig.apply(AutoConfig.diagnose(log: ak, current: []), game: plain)
        check(AutoConfig.currentArgs(game: plain) == ["--accessibility", "disabled"], "apply appends")
        try? FileManager.default.removeItem(at: root)
        print("auto config ok")
    }
}
