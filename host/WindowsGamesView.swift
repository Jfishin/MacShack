import SwiftUI

// Windows games in one place: who made each piece, Set up, Remove. Opened from
// Settings and from MacShack Play's own screen (<MacShack's bundle id>://windows-games, AppModel.receive).
struct WindowsGamesView: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    @State private var askRemove = false
    @State private var games: (count: Int, bytes: Int64) = (0, 0)

    var body: some View {
        let setup = app.windowsSetup
        NavigationStack {
            Form {
                Section {
                    ForEach(WindowsKit.credits) { credit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(credit.piece).font(.headline)
                            Text("\(credit.maker) · \(credit.license)").font(.subheadline).foregroundStyle(.secondary)
                            Link(credit.link.absoluteString, destination: credit.link).font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Who made what") } footer: {
                    Text("Madeira and Valve's files are downloaded on this device from their makers. NotProton's and Valve's Proton parts come in MacShack's Windows kit (GPL-3.0, source in windows-kit/). None of them is built into the MacShack app.")
                }
                Section {
                    if setup.restartNeeded {
                        Label("Restart MacShack to finish: swipe it away in the app switcher, then open it again.", systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    }
                    if let stamp = WindowsSetup.stamp, setup.state != .working("Removing") {
                        LabeledContent("Set up", value: "Madeira \(stamp.madeira), kit \(stamp.kit)")
                        if WindowsSetup.playInstalled {
                            Button("Open MacShack Play") {
                                if let url = URL(string: ShackPlayHostBundleID() + ".play://") { UIApplication.shared.open(url) }
                            }
                        }
                        Button("Remove Windows games", role: .destructive) {
                            Task { games = await offMain { WindowsSetup.installedGames() }; askRemove = true }   // walks the library: off the main thread
                        }
                    } else {
                        switch setup.state {
                        case .idle:
                            Button("Set up Windows games") { setup.start() }.disabled(!WindowsSetup.playInstalled)
                            if !WindowsSetup.playInstalled {
                                Text("Install MacShack Play first: build its scheme in Xcode.").foregroundStyle(.secondary)
                            }
                        case .downloading(let name, let bytes):
                            LabeledContent("Downloading \(name)", value: "\(bytes / 1_000_000) MB")
                            Button("Cancel") { setup.cancel() }
                        case .working(let step):
                            HStack(spacing: 12) { ProgressView(); Text("\(step)…") }
                        case .failed(let message):
                            Text(message).foregroundStyle(.secondary)
                            Button("Retry") { setup.start() }
                        }
                    }
                } header: { Text("Windows games") } footer: {
                    Text("Windows games from Steam turn on, or off after Remove, when MacShack next starts. They run in MacShack Play. Setting up needs 2 GB free while it runs.")
                }
            }
            .themed()
            .navigationTitle("Windows games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark", action: close) } }
            .confirmationDialog("Remove Windows games?", isPresented: $askRemove, titleVisibility: .visible) {
                Button(games.count > 0 ? "Remove, keep \(games.count) installed game\(games.count == 1 ? "" : "s")" : "Remove") {
                    setup.remove(deleteGames: false)
                }
                if games.count > 0 {
                    Button("Remove and delete \(games.count) game\(games.count == 1 ? "" : "s") (\(String(format: "%.1f", Double(games.bytes) / 1e9)) GB)",
                           role: .destructive) { setup.remove(deleteGames: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The engine, the kit and Valve's files are deleted. Installed Windows games and their local saves stay unless you delete them too; Steam finds kept games again if you set up Windows games later. Steam Cloud saves are not touched.")
            }
        }
        .padHandler { press in   // B closes the page, as in Settings
            guard press == .b else { return false }
            close()
            return true
        }
    }
}
