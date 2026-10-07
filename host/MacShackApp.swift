import SwiftUI
import GameController

@main
struct MacShackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()
    @State private var pad = PadNav()
    @State private var look = Appearance()
    @State private var password = ""
    // The first screen, unless MacShack starts with arguments or relaunches itself into a game: then Local Games.
    private static let onHome = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--") } ||
        UserDefaults.standard.string(forKey: "pendingLaunch") != nil
    // First run: onboarding until a valid signing identity and a pairing file are in (never for test launches). Once
    // shown it stays until its last page is left.
    @State private var onboarding = !MacShackApp.onHome && (!AppModel.identityValid || !AppModel.hasPairingFile)

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarding {
                    OnboardingView { bigPicture in
                        onboarding = false
                        if bigPicture { DispatchQueue.main.async { app.openBigPicture() } }   // after the launcher is in
                    }
                } else {
                    // Launching a game replaces this whole view: the AppKit shim installs the game's own root view controller.
                    LauncherView(start: app.showProbe ? .settings : Self.onHome ? .games : nil)
                }
            }
            .environment(app)
            .environment(pad)
            .environment(look)
            .tint(look.accent)
            // Also runs again when onboarding hands over to the launcher (the Group's content changes): keep it idempotent.
            .onAppear {
                pad.suspended = { [app] in app.launched && app.ended == nil }
                pad.start()
                _ = DeviceInfo.chip   // read the chip name now: a game's Metal hooks come later
                _ = GCController.controllers()   // start controller discovery long before a game's first HID scan
                app.handleLaunchArguments()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { app.scan() } }
            .onOpenURL { app.receive($0) }   // AirDrop / "Open in": a .p12 or a pairing file
            .alert(app.certificateReady ? "Replace signing identity?" : "Import development .p12", isPresented: $app.askPassword) {
                SecureField("Export password", text: $password)
                Button("Cancel", role: .cancel) { app.pendingCertificate = nil; password = "" }
                Button("Import") { app.importPendingCertificate(password: password); password = "" }
            } message: {
                Text("Enter the password you chose when exporting this .p12 from Keychain Access.")
            }
        }
    }
}
