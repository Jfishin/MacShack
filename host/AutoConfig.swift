import Foundation

// Launch arguments some games need that the shims cannot supply.
// Documents/Games/<Name>.args is remembered by bundle id in Library/GameConfigs (Delete leaves it), restored after a
// reinstall, and extended when a known failure shows in the game's log. Foundation only: the Mac check builds it alone.
enum AutoConfig {
    // Hand-found fixes, by CFBundleIdentifier.
    static let known: [String: [String]] = [
        "com.johnpywell.fountains": ["--rendering-driver", "opengl3_angle", "--accessibility", "disabled"],   // Godot 4.5 Compatibility
        "com.walaber.garagerally": ["--rendering-method", "forward_plus"],   // Godot 4 Mobile deadlock on 6 cores
        // arm64 Solar2D/CoronaCards: OpenGL only, through ShackGL's CGL; and everything on UIKit's main thread, as on a Mac
        // (its Lua state is not thread safe: controller and notification callbacks arrive on the main thread, its own timer
        // on the app thread, and the two crashed in lua_getinfo together).
        "com.tragsoft.coromon": ["--shack-env=SHACK_OPENGL=1", "--shack-env=SHACK_APP_THREAD=main"],
        // BlackSpace needs the publisher trust bridge, a 540p desktop, and a single stage for native Metal 4 timestamps.
        "com.pearlabyss.CrimsonDesert.steam": ["--shack-env=SHACK_MAC_CODESIGN=1", "--shack-env=SHACK_CTYPE=UTF-8", "--shack-env=SHACK_DISPLAY_SIZE=960x540", "--shack-env=SHACK_METAL4_TIMESTAMP_STAGE=1", "Width=960", "Height=540"],
        "com.linceworks.aragami": ["-force-glcore"],   // Intel Unity 2017 with GL shaders only: no -force-metal (ShackLoader)
        // Feral (Intel, AArchX): OpenGL; its engine asks pthread_main_np, so the app thread is the UIKit main thread;
        // -no-feral-options skips the pre-game options window, an HTML page in the legacy WebView iOS does not have.
        "com.feralinteractive.bioshockremastered": ["--shack-env=SHACK_OPENGL=1", "--shack-env=SHACK_APP_THREAD=main", "-no-feral-options"],
        // Feral, i386 (AArchX m32): the same OpenGL and main-thread model; its options window is skipped by its own
        // registry (GameOptionsDialogShouldShow=0), and IndirectX takes its GLSL path (UseGLSL=1) - ShackGL has no ARB programs.
        "com.feralinteractive.bmaa": ["--shack-env=SHACK_OPENGL=1", "--shack-env=SHACK_APP_THREAD=main"],
    ]
    struct Rule { let signatures: [String]; let args: [String] }
    // A log containing every signature needs `args`. ponytail: plain substring match; add rules as games show them.
    static let rules = [
        Rule(signatures: ["Unable to initialize OpenGL video driver"], args: ["--rendering-driver", "opengl3_angle"]),   // Godot GL → ANGLE
        Rule(signatures: ["accesskit_macos", "panicked"], args: ["--accessibility", "disabled"]),   // Godot 4.5 AccessKit
        // An Intel Unity build without Metal shaders refuses the -force-metal ShackLoader adds; any renderer switch
        // in the .args stops that, and its desktop GL runs on ShackGL's CGL.
        Rule(signatures: ["Forced GfxDevice 'Metal' was not built from editor"], args: ["-force-glcore"]),
    ]
    static var store: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("GameConfigs", isDirectory: true)
    }

    static func argsURL(game: URL) -> URL { game.deletingPathExtension().appendingPathExtension("args") }
    static func bundleID(game: URL) -> String? {
        NSDictionary(contentsOf: game.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }
    // ShackLoader.m guestArgs writes this when there is no .args: Unity's flags for Unity games, else nothing.
    static func defaultText(game: URL) -> String {
        FileManager.default.fileExists(atPath: game.appendingPathComponent("Contents/Resources/Data").path) ? "-stdout\n-FullStdOutLogOutput\n-nosplash\n" : ""
    }
    static func currentArgs(game: URL) -> [String] {
        ((try? String(contentsOf: argsURL(game: game), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Before a launch: a custom .args is remembered; a missing or default one gets the remembered config, else the known fix.
    static func prepare(game: URL, store: URL = store) {
        guard let id = bundleID(game: game) else { return }
        let file = argsURL(game: game), saved = store.appendingPathComponent("\(id).args")
        let text = try? String(contentsOf: file, encoding: .utf8)
        if let text, text != defaultText(game: game) {
            try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try? text.write(to: saved, atomically: true, encoding: .utf8)
            return
        }
        guard let seed = (try? String(contentsOf: saved, encoding: .utf8)) ?? known[id].map({ $0.joined(separator: "\n") + "\n" }) else { return }
        try? seed.write(to: file, atomically: true, encoding: .utf8)
        NSLog("[AutoConfig] %@: seeded %@", id, file.lastPathComponent)
        prepare(game: game, store: store)   // remember it as well
    }

    static func diagnose(log: String, current: [String]) -> [Rule] {
        rules.filter { rule in rule.signatures.allSatisfy(log.contains) && !current.contains(rule.args[0]) }
    }

    static func apply(_ rules: [Rule], game: URL) {
        let lines = currentArgs(game: game) + rules.flatMap(\.args)
        try? (lines.joined(separator: "\n") + "\n").write(to: argsURL(game: game), atomically: true, encoding: .utf8)
    }
}
