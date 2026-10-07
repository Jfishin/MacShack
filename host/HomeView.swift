import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(PadNav.self) private var pad
    let close: () -> Void   // back to the first screen (also B)
    static let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 16, alignment: .top)]
    @State private var focus = 0
    @State private var gridWidth: CGFloat = 0
    @State private var options: URL?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                StatusBanner()
                if !app.staged.isEmpty {
                    Text("Ready to prepare").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    LazyVGrid(columns: Self.columns, spacing: 20) { ForEach(app.staged, id: \.self) { StagedTile(url: $0) } }
                        .padding(.horizontal)
                }
                LazyVGrid(columns: Self.columns, spacing: 20) {
                    ForEach(Array(app.games.enumerated()), id: \.element) { i, url in
                        GameTile(url: url, focused: pad.active && i == focus).id(url)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding()
                if app.games.isEmpty && app.staged.isEmpty {
                    ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                        description: Text("Copy an unmodified .app, or the game's whole Mac folder, into MacShack/Staging with Files."))
                }
            }
            .themed(picture: true)
            .onChange(of: focus) { _, i in
                if app.games.indices.contains(i) { withAnimation { scroll.scrollTo(app.games[i], anchor: .center) } }
            }
            }
            .navigationTitle("Local Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark", action: close) } }
            .refreshable { app.scan() }
            .sheet(isPresented: Binding { options != nil } set: { if !$0 { options = nil } }) { if let options { GameOptions(url: options) } }
            .alert("Prepare \(app.stalePrepare.map { app.displayName($0.url) } ?? "") again?",
                   isPresented: Binding { app.stalePrepare != nil } set: { if !$0 { app.stalePrepare = nil } },
                   presenting: app.stalePrepare) { stale in
                Button("Prepare again") { app.prepare(stale.url) { ok, _ in if ok { app.launch(stale.url) } } }   // then it plays, as tapped
                Button("Cancel", role: .cancel) {}
            } message: { stale in Text(stale.reason) }
        }
        .padHandler { press in   // A plays, Y opens the frame cap and memory swap, B closes
            if press == .b { close(); return true }
            let games = app.games
            guard !games.isEmpty else { return false }
            focus = min(focus, games.count - 1)
            switch press {
            case .a: if !app.busy { app.launch(games[focus]) }
            case .y: options = games[focus]
            default:
                guard let j = gridMove(press, from: focus, count: games.count, columns: gridColumns(width: gridWidth)) else { return false }
                focus = j
            }
            return true
        }
    }
}

// Tap to play; hold for the frame cap, a forced resolution, memory swap, Prepare again, the game's log and Archive.
struct GameTile: View {
    @Environment(AppModel.self) private var app
    let url: URL
    var focused = false
    @AppStorage private var cap: Int
    @AppStorage private var swapMB: Int
    @AppStorage private var displaySize: String
    @AppStorage private var scale: Double
    @AppStorage("fpsCap") private var defaultCap = 60   // ShackGameFrameCap's default
    @State private var showLog = false
    @State private var confirmDelete = false

    init(url: URL, focused: Bool = false) {
        self.url = url
        self.focused = focused
        _cap = AppStorage(wrappedValue: -1, "fpsCap.\(url.deletingPathExtension().lastPathComponent)")
        _swapMB = AppStorage(wrappedValue: 0, "swapMB.\(url.deletingPathExtension().lastPathComponent)")   // ShackLoader's key; 0 = off
        _displaySize = AppStorage(wrappedValue: "", "displaySize.\(url.deletingPathExtension().lastPathComponent)")   // ShackLoader's key
        _scale = AppStorage(wrappedValue: 0, "renderScale.\(url.deletingPathExtension().lastPathComponent)")   // ShackLoader's key
    }
    // The desktop the game sees (16:9, letterboxed on the phone); "" = the phone's own screen.
    private static let displaySizes = [("540p", "960x540"), ("720p", "1280x720"), ("900p", "1600x900"), ("1080p", "1920x1080")]
    private var name: String { app.displayName(url) }

    var body: some View {
        Button { app.launch(url) } label: {
            VStack(spacing: 6) {
                ArtTile(title: name, aspect: 1, focused: focused) {
                    if let icon = await Artwork.icon(forApp: url) { return icon }
                    return nil
                }
                .overlay(alignment: .topTrailing) { TypeBadge(url: url) }
                Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(app.busy)
        .contextMenu {
            Picker("Frame cap", selection: $cap) {
                Text("Default (\(capLabel(defaultCap)))").tag(-1)
                CapChoices()
            }
            .pickerStyle(.menu)
            // One picker for both keys: a render scale fills the screen, a forced size is letterboxed (and wins in the loader).
            Picker("Resolution", selection: Binding { displaySize.isEmpty ? String(scale) : displaySize }
                                                set: { if let s = Double($0) { scale = s; displaySize = "" } else { displaySize = $0; scale = 0 } }) {
                Text("Default").tag(String(0.0))
                Section("Full screen") { ForEach(renderScales, id: \.self) { Text(scaleLabel($0)).tag(String($0)) } }
                Section("16:9, letterboxed") { ForEach(Self.displaySizes, id: \.1) { Text($0.0).tag($0.1) } }
            }
            .pickerStyle(.menu)
            Toggle("Memory swap", systemImage: "memorychip", isOn: Binding { swapMB != 0 } set: { swapMB = $0 ? 6144 : 0 })
            Button("Prepare again", systemImage: "arrow.triangle.2.circlepath") { app.prepare(url) }
            Button("View log", systemImage: "doc.text") { showLog = true }
            Button("Archive", systemImage: "archivebox", role: .destructive) { app.archive(url) }
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .deleteConfirmation($confirmDelete, name: name) { app.delete(url) }
        .sheet(isPresented: $showLog) { NavigationStack { LogView(file: app.logURL(for: url)) } }
    }
}

// Frame cap and memory swap for one game, for a controller (Y on Home) as well as touch: left/right changes the
// cap, X toggles swap, B closes. Same settings as the tile's context menu.
struct GameOptions: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let url: URL
    @AppStorage private var cap: Int
    @AppStorage private var swapMB: Int
    @AppStorage private var scale: Double
    @AppStorage("fpsCap") private var defaultCap = 60   // ShackGameFrameCap's default

    init(url: URL) {
        self.url = url
        _cap = AppStorage(wrappedValue: -1, "fpsCap.\(url.deletingPathExtension().lastPathComponent)")
        _swapMB = AppStorage(wrappedValue: 0, "swapMB.\(url.deletingPathExtension().lastPathComponent)")
        _scale = AppStorage(wrappedValue: 0, "renderScale.\(url.deletingPathExtension().lastPathComponent)")   // ShackLoader's key
    }
    private static let scales: [Double] = [0] + renderScales
    private func stepScale(_ d: Int) {
        let i = Self.scales.firstIndex(of: scale) ?? 0
        scale = Self.scales[max(0, min(Self.scales.count - 1, i + d))]
    }
    private var title: String { app.displayName(url) }
    private var caps: [Int] { [-1, 0] + (2...5).map { displayHz / $0 }.filter { $0 >= 24 } }
    private func label(_ c: Int) -> String { c == -1 ? "Default (\(capLabel(defaultCap)))" : capLabel(c) }
    private func step(_ d: Int) {
        let i = caps.firstIndex(of: cap) ?? 0
        cap = caps[max(0, min(caps.count - 1, i + d))]
    }

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.title2.bold())
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Text("Frame cap: \(label(cap))").frame(minWidth: 220)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
            }
            HStack {
                Button { stepScale(-1) } label: { Image(systemName: "chevron.up") }
                Text("Resolution: \(scaleLabel(scale))").frame(minWidth: 220)
                Button { stepScale(1) } label: { Image(systemName: "chevron.down") }
            }
            Toggle("Memory swap (X)", systemImage: "memorychip", isOn: Binding { swapMB != 0 } set: { swapMB = $0 ? 6144 : 0 })
                .frame(maxWidth: 300)
            Text("◀ ▶ frame cap · ▲ ▼ resolution · X swap · B close").font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .presentationDetents([.medium])
        .padHandler { press in
            switch press {
            case .left: step(-1)
            case .right: step(1)
            case .up: stepScale(-1)
            case .down: stepScale(1)
            case .x: swapMB = swapMB != 0 ? 0 : 6144
            case .b: dismiss()
            default: break
            }
            return true   // modal: nothing reaches Home underneath
        }
    }
}

// Which kind of game this is: Intel under AArchX, native arm64 that needs JIT (Unity Mono), or plain native arm64.
struct TypeBadge: View {
    @Environment(AppModel.self) private var app
    let url: URL

    var body: some View {
        Group {
            if app.intelGames.contains(url) { Label("Intel", systemImage: "applelogo") }
            else if app.jitGames.contains(url) { Label("Arm+JIT", systemImage: "applelogo") }
            else { Label("Arm", systemImage: "applelogo") }
        }
        .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule()).padding(6)
    }
}

struct StagedTile: View {
    @Environment(AppModel.self) private var app
    let url: URL
    @State private var confirmDelete = false
    private var name: String { url.deletingPathExtension().lastPathComponent }

    var body: some View {
        VStack(spacing: 6) {
            ArtTile(title: name, aspect: 1) { await Artwork.icon(forApp: url) }.opacity(0.6)
            Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            Button("Prepare") { app.prepare(url) }.buttonStyle(.borderedProminent).controlSize(.small).disabled(app.busy)
        }
        .contextMenu { Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(app.busy) }
        .deleteConfirmation($confirmDelete, name: name) { app.delete(url) }
    }
}

extension View {
    // Deleting a game cannot be undone (Archive can): ask first.
    func deleteConfirmation(_ shown: Binding<Bool>, name: String, delete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete \(name)?", isPresented: shown, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: { Text("Removes the game and its prepared code. Saves stay.") }
    }
}

// Prepare and launch progress, JIT instructions and the last error, above the grid.
struct StatusBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let offer = app.configOffer {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(offer.game.deletingPathExtension().lastPathComponent) needs configuration to start. Set up auto-config?",
                          systemImage: "wrench.and.screwdriver")
                    HStack {
                        Button("Set up auto-config") { app.applyConfig() }.buttonStyle(.borderedProminent)
                        Button("Not now") { app.configOffer = nil }
                    }
                }.font(.footnote)
            }
            if let name = app.ended {
                Label("\(name) closed. Pick a game: MacShack reopens into it.", systemImage: "checkmark.circle").font(.footnote)
            }
            if app.preparing { ProgressView { Text(app.preparationStatus) } }
            else if !app.preparationStatus.isEmpty { Text(app.preparationStatus).font(.footnote).foregroundStyle(.secondary) }
            if !app.jitStatus.isEmpty { Label(app.jitStatus, systemImage: "bolt.fill").font(.footnote) }
            if let e = app.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}

// Frame caps are whole numbers of display refreshes (120 Hz: 60/40/30/24) so every frame stays on screen equally
// long; 0 = uncapped (up to the display's rate). The loader reads `fpsCap.<Name>`, else the default `fpsCap`.
@MainActor var displayHz: Int { UIScreen.main.maximumFramesPerSecond }   // ponytail: main screen; games only run on the device's own panel
@MainActor func capLabel(_ cap: Int) -> String { cap == 0 ? "\(displayHz) (uncapped)" : "\(cap) fps" }
// Render scales (`renderScale.<Name>`): full screen, fewer pixels, cooler GPU. 0 = the default (`renderScale`, else 2x).
let renderScales: [Double] = [3, 2, 1.5, 1]
@MainActor func scaleName(_ s: Double) -> String {
    let screen = UIScreen.main
    return s == screen.scale ? "Full Retina" : s == screen.scale / 2 ? "Half Retina" : "\(s.formatted())x"
}
@MainActor func scaleLabel(_ s: Double) -> String {
    let p = UIScreen.main.bounds.size
    return s == 0 ? "Default" : "\(scaleName(s)) (\(Int(max(p.width, p.height) * s))×\(Int(min(p.width, p.height) * s)))"
}

struct CapChoices: View {
    var body: some View {
        Text(capLabel(0)).tag(0)
        ForEach((2...5).map { displayHz / $0 }.filter { $0 >= 24 }, id: \.self) { Text(capLabel($0)).tag($0) }
    }
}
