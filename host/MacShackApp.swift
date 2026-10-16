import SwiftUI
import GameController

@main
struct MacShackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()
    @State private var pad = PadNav()
    @State private var look = Appearance()
    @State private var password = ""
    // The first screen, unless MacShack starts with arguments: then Local Games.
    private static let onHome = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--") }
    // First run: onboarding until a valid signing identity and a pairing file are in, or the pairing page was skipped
    // (never for test launches). Once shown it stays until its last page is left.
    @State private var onboarding = !MacShackApp.onHome && (!AppModel.identityValid ||
        (!AppModel.hasPairingFile && !UserDefaults.standard.bool(forKey: "onboarding.pairingSkipped")))

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarding {
                    OnboardingView { bigPicture in
                        onboarding = false
                        if bigPicture { DispatchQueue.main.async { app.openBigPicture() } }   // after the launcher is in
                    }
                } else {
                    // Starting Steam replaces this whole view: the AppKit shim installs Steam's own root view controller.
                    LauncherView(start: app.showProbe ? .settings : Self.onHome ? .games : nil)
                }
            }
            .environment(app)
            .environment(pad)
            .environment(look)
            .tint(look.accent)
            // Also runs again when onboarding hands over to the launcher (the Group's content changes): keep it idempotent.
            .onAppear {
                pad.suspended = { [app] in app.launched && !app.ended }
                pad.start()
                _ = DeviceInfo.chip   // read the chip name now: Steam's Metal hooks come later
                _ = GCController.controllers()   // start controller discovery long before Steam's first HID scan
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
