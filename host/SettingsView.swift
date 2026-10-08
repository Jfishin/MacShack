import SwiftUI
import UniformTypeIdentifiers

// Every setting, top to bottom: Big Picture, the Steam client, game defaults, look, advanced, this device. Close or B
// returns to the first screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    let close: () -> Void
    let setUpSteam: (SteamSetup.Mode) -> Void   // update or repair: LauncherView runs SteamSetupView
    let windowsGames: () -> Void   // LauncherView shows WindowsGamesView
    @AppStorage("metalHUD") private var metalHUD = false
    // How hard Big Picture and the games it starts may work the phone. Low Power Mode runs the UI at 60 Hz and stays
    // cool; uncapped, Chromium drew Big Picture at the panel's 120 Hz and full 3x resolution.
    @AppStorage("steamUI.fpsCap") private var uiCap = 60   // ShackSteamUIFrameCap's default
    @AppStorage("steamUI.renderScale") private var uiScale = 2.0   // ShackSteamUIRenderScale's default
    @AppStorage("steamSleep") private var sleep = true
    @AppStorage("steamClient.lockTested") private var lockTested = true   // SteamSetup.lockTested

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Picker("Frame rate", selection: $uiCap) { CapChoices() }
                    Picker("Resolution", selection: $uiScale) {
                        ForEach(renderScales, id: \.self) { Text(scaleLabel($0)).tag($0) }
                    }
                } header: { Text("Steam Big Picture") } footer: {
                    Text("Lower draws fewer frames and pixels: less power, less heat. The frame rate also changes from the MacShack menu; resolution when Steam starts. Hold \(DeviceInfo.menuSpot) in Steam or in a game for the MacShack menu.")
                }
                Section {
                    Toggle("Sleep Steam during games", isOn: $sleep)
                } footer: {
                    Text("Big Picture stops drawing while a game has the screen. Steam itself keeps running, so achievements, cloud saves and friends still work.")
                }
                Section {
                    LabeledContent("Installed", value: SteamSetup.installedLabel)
                    Toggle("Lock to tested version", isOn: $lockTested)
                    Button("Update to latest Steam") { lockTested = false; setUpSteam(.update) }
                    Button("Repair Steam") { setUpSteam(.repair) }
                } header: { Text("Steam client") } footer: {
                    Text("Tested is the Steam this MacShack was tested with. Update brings Valve's newest, untested. Repair downloads and prepares all of Steam again. Your sign-in, games and settings stay.")
                }
                if WindowsSetup.playInstalled || WindowsSetup.stamp != nil {
                    Section {
                        Button("Windows games") { windowsGames() }
                    } header: { Text("Windows games") } footer: {
                        Text(WindowsSetup.stamp != nil ? "Set up: Windows games from Steam run in MacShack Play."
                                                       : "MacShack Play is installed. Set up Windows games to play them from Steam.")
                    }
                }
                GameDefaultsSection()
                Section {
                    NavigationLink { CustomizeView() } label: { Label("Customization", systemImage: "paintpalette") }
                }
                Section("Advanced") {
                    Toggle("Metal performance HUD", isOn: $metalHUD)
                    NavigationLink("JIT & signing") { JITSigningView() }
                    NavigationLink("Logs") { LogBrowser() }
                    NavigationLink("Self-test") { ProbeView() }
                    if !app.jitStatus.isEmpty { Text(app.jitStatus).font(.footnote) }
                    if let e = app.error { Text(e).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                }
                HardwareSection()
            }
            .themed()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark", action: close) } }
            .navigationDestination(isPresented: $app.showProbe) { ProbeView() }
        }
        .padHandler { press in   // ponytail: B closes Settings from a pushed page too
            guard press == .b else { return false }
            close()
            return true
        }
    }
}

// Every game's frame cap and resolution unless its own (its tile menu in Local Games, the MacShack menu) says otherwise. Lower is
// cooler: Low Power Mode holds the panel to 60, which is the default cap.
struct GameDefaultsSection: View {
    @AppStorage("fpsCap") private var defaultCap = 60   // ShackGameFrameCap's default
    @AppStorage("renderScale") private var defaultScale = 2.0   // ShackGameRenderScale's default
    var body: some View {
        Section {
            Picker("Frame cap", selection: $defaultCap) { CapChoices() }
            Picker("Resolution", selection: $defaultScale) {
                ForEach(renderScales, id: \.self) { Text(scaleLabel($0)).tag($0) }
            }
        } header: { Text("Games") } footer: {
            Text("A game's own setting wins: its tile in Local Games, or the MacShack menu while it runs. The frame cap changes at once from that menu; resolution at the next launch.")
        }
    }
}

// The one-time setup, also done by onboarding: the development identity MacShack signs games with, and the pairing file
// its own JIT needs. Both pickers (and AirDrop) go through AppModel.receive; the .p12's password prompt is MacShackApp's.
struct JITSigningView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var showPairingImporter = false

    var body: some View {
        Form {
            Section {
                Button("Import development .p12") { showImporter = true }.disabled(app.busy)
                Button("Sign and load test library") { app.runSigningProof() }.disabled(app.busy)
                if !app.signingStatus.isEmpty { Text(app.signingStatus).font(.footnote).textSelection(.enabled) }
            } header: { Text("Signing identity") } footer: {
                Text("One-time setup: on your Mac open Keychain Access > My Certificates, export the Apple Development identity used to sign MacShack as .p12 with a password, and AirDrop it to this device. The identity stays in this device's When Unlocked keychain.")
            }
            Section {
                LabeledContent("Pairing file", value: app.pairingReady ? "Imported" : "None (uses StikDebug)")
                Button("Import pairing file") { showPairingImporter = true }
                    .fileImporter(isPresented: $showPairingImporter, allowedContentTypes: [.propertyList, .data]) { result in
                        if case .success(let url) = result { app.receive(url) }
                    }
                if !app.jitStatus.isEmpty { Text(app.jitStatus).font(.footnote) }
            } header: { Text("JIT") } footer: {
                Text("Unity and Intel games need JIT. With an RPPairing file (idevice_pair's RPPairing format, or the one StikDebug uses) MacShack enables it itself: keep LocalDevVPN connected and Developer Mode on. After a reboot the first launch also downloads and mounts the Developer Disk Image.")
            }
        }
        .themed()
        .navigationTitle("JIT & Signing")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12]) { result in
            if case .success(let url) = result { app.receive(url) }
        }
    }
}

// Every log MacShack and its games write: Documents/Logs and the games' own logs under Library/Logs (Unity's
// Player.log), newest first.
struct LogBrowser: View {
    @State private var files: [URL] = []
    var body: some View {
        List(files, id: \.self) { file in
            NavigationLink { LogView(file: file) } label: {
                VStack(alignment: .leading) {
                    Text(file.lastPathComponent)
                    Text(file.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Logs")
        .onAppear { files = Self.scan() }
    }

    static func scan() -> [URL] {
        let fm = FileManager.default
        let roots = [AppModel.logs, fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")]
        var found: [URL] = []
        for root in roots {
            let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            while let url = walker?.nextObject() as? URL {
                if url.pathExtension == "log" { found.append(url) }
            }
        }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return found.sorted { date($0) > date($1) }
    }
}

// The last 200 KB of a log (game logs grow to megabytes), selectable, with a share button for the whole file.
struct LogView: View {
    let file: URL
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(empty or missing)" : text)
                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(file.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: file) }
        .task { text = Self.tail(file) }
    }

    static func tail(_ file: URL, bytes: UInt64 = 200_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
