// Simulator preview of MacShack's first screen (host/Launcher.swift) without the rest of MacShack, which has no
// simulator build. Booted simulator:
// S=$(xcrun --sdk iphonesimulator --show-sdk-path); A=/tmp/Launcher.app; mkdir -p $A
// swiftc -parse-as-library -target arm64-apple-ios26.0-simulator -sdk $S host/Launcher.swift host/PadNav.swift \
//   host/probe/test_launcher.swift -o $A/Launcher && cp host/probe/test_launcher.plist $A/Info.plist && codesign -fs - $A
// xcrun simctl install booted $A && xcrun simctl launch booted com.example.launcher-preview [-steamReady NO]
// xcrun simctl io booted screenshot /tmp/launcher.png
import SwiftUI

@main
struct LauncherPreview: App {
    @State private var pad = PadNav()
    @State private var pressed = ""

    var body: some Scene {
        WindowGroup {
            LauncherScreen(steamReady: UserDefaults.standard.string(forKey: "steamReady") != "NO",
                           bigPicture: { pressed = "Big Picture" }, localGames: { pressed = "Local Games" },
                           settings: { pressed = "Settings" })
                .overlay(alignment: .bottom) { Text(pressed).foregroundStyle(.white).padding() }
                .environment(pad)
                .onAppear { pad.start() }
        }
    }
}
