import SwiftUI

// Wires the first screen (host/Launcher.swift) to MacShack. Local Games (HomeView) and Settings take its place rather than
// sit over it: a game's AppKit shim replaces the window's root view controller, and a presented page would stay on
// top. Steam setup (missing or not current Steam) covers everything, then Big Picture opens.
struct LauncherView: View {
    @Environment(AppModel.self) private var app
    @State private var page: Page?
    @State private var setupMode: SteamSetup.Mode?   // SteamSetupView over the launcher
    @State private var bootAfterSetup = false   // Big Picture once the setup cover is gone
    enum Page { case games, settings, windowsGames }

    init(start: Page?) { _page = State(initialValue: start) }

    var body: some View {
        Group {
            switch page {
            case nil:
                LauncherScreen(steamReady: AppModel.steamClientReady, modal: setupMode != nil, bigPicture: openBigPicture,
                               localGames: { page = .games }, settings: { page = .settings })
                    // Errors raised here (Big Picture did not start) have no other place on this screen.
                    .alert("Something went wrong", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
                        Button("OK", role: .cancel) {}
                    } message: { Text(app.error ?? "") }
            case .games: HomeView(close: { page = nil })
            case .settings: SettingsView(close: { page = nil }, setUpSteam: { page = nil; setupMode = $0 }, windowsGames: { page = .windowsGames })
            case .windowsGames: WindowsGamesView(close: { page = nil })
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: app.openPage, initial: true) { _, wanted in   // initial: asked for before this view appeared (onboarding)
            guard let wanted else { return }
            page = wanted
            app.openPage = nil
        }
        .fullScreenCover(item: $setupMode, onDismiss: { if bootAfterSetup { bootAfterSetup = false; app.openBigPicture() } }) { mode in
            SteamSetupView(mode: mode, done: { bootAfterSetup = true; setupMode = nil }, close: { setupMode = nil })
                .background(LauncherBackground())
                .preferredColorScheme(.dark)
        }
    }

    // Set up and current: Big Picture at once. Otherwise setup first (install, the tested version, or Valve's latest).
    private func openBigPicture() {
        if SteamSetup.isCurrent { app.openBigPicture() } else { setupMode = .open }
    }
}
