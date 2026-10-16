import SwiftUI
import UIKit

// Local state behind the launcher, Local Games and Settings: what is in Documents/Staging and Documents/Games, the
// on-device prepare, starting games in MacShack Play, the Steam client (once per process: its hooks are process-wide),
// and the signing identity.
@Observable
@MainActor
final class AppModel {
    var games: [URL] = []
    var staged: [URL] = []
    var jitGames: Set<URL> = []       // Unity Mono and Intel games: both need JIT
    var intelGames: Set<URL> = []     // the x86_64 ones, run under AArchX
    var preparing = false
    var preparationStatus = ""
    var jitStatus = ""
    var error: String?
    var launched = false   // the Steam client runs in this process
    var signingBusy = false
    var signingStatus = ""
    let steamSetup = SteamSetup()   // Valve's Steam client onto this device (SteamSetup.swift)
    let windowsSetup = WindowsSetup()   // Windows games onto this device (WindowsSetup.swift)
    var openPage: LauncherView.Page?    // a page another app asked for (MacShack Play's "Set up Windows games")
    var pendingCertificate: Data?   // a received .p12 waiting for its password (MacShackApp's prompt)
    var askPassword = false
    var certificateReady = AppModel.identityValid   // onboarding: a valid identity whose test library loaded
    var pairingReady = AppModel.hasPairingFile
    var showProbe = ProcessInfo.processInfo.arguments.contains("--probe")
    @ObservationIgnored private var autoLaunched = false
    var ended = false   // Steam quit: MacShack is back, and Big Picture needs a fresh process
    var configOffer: (game: URL, rules: [AutoConfig.Rule])?   // Local Games asks to set up auto-config (AutoConfig.swift)
    @ObservationIgnored private var hostRoot: UIViewController?

    var busy: Bool { (launched && !ended) || preparing || signingBusy }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var logs: URL {
        let dir = documents.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func executable(of url: URL) -> String {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
    }

    init() {
        // Before anything reads Application Support (Appearance does, right after this object: MacShackApp creates
        // AppModel first): MacShack's Library folders become links into the shared home, moved there the first time.
        _ = ShackHomeEnsure()
        _ = ShackHomePrefsSync()
        ShackHomeMirrorLogs()
        NotificationCenter.default.addObserver(forName: Notification.Name("ShackGameNotStarted"), object: nil, queue: .main) { [weak self] note in
            let why = note.object as? String
            MainActor.assumeIsolated {   // over Big Picture the island overlay says it (GameOverlay.swift)
                guard let self, !self.launched || self.ended else { return }
                self.error = why
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("ShackGuestExited"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameEnded() }
        }
    }

    // Steam quit (its main returned): MacShack's own screen comes back. Big Picture needs a fresh process.
    private func gameEnded() {
        guard launched, !ended else { return }
        GameOverlay.hide()
        _ = ShackHomePrefsSync()   // Steam's settings for MacShack Play
        ShackHomeMirrorLogs()
        if let root = hostRoot, let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first {
            window.rootViewController = root
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        ended = true
        scan()
    }

    func scan() {
        guard !preparing && (!launched || ended) else { return }
        pairingReady = Self.hasPairingFile   // a pairing file can also arrive by Files or devicectl
        do { try ShackInstaller.recoverInterruptedInstalls() } catch { self.error = error.localizedDescription }
        games = apps(in: "Games")
        staged = apps(in: "Staging")
        jitGames = Set(games.filter { ShackInstaller.requiresJIT(atAppPath: $0.path) })
        intelGames = Set(games.filter { ShackInstaller.translates(atAppPath: $0.path) })
    }

    // What a tile shows: the folder name, which is also the key for saves, logs and settings.
    func displayName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private func apps(in folder: String) -> [URL] {
        let dir = Self.documents.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var found = items.filter { $0.pathExtension == "app" }
        if folder == "Staging" { found += items.compactMap(StagedFolder.game) }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func prepare(_ url: URL) {
        guard !busy else { return }
        preparing = true
        error = nil
        preparationStatus = "Preparing \(url.deletingPathExtension().lastPathComponent)…"
        UIApplication.shared.isIdleTimerDisabled = true
        let path = url.path, log = Self.logs.appendingPathComponent("preparation.log")
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                let app = try StagedFolder.unpack(URL(fileURLWithPath: path), staging: Self.documents.appendingPathComponent("Staging"), games: Self.documents.appendingPathComponent("Games"))
                result = try ShackInstaller.installApp(atPath: app.path)
                Self.forgetPlayCopy(app.deletingPathExtension().lastPathComponent, code: false)
            } catch { result = error.localizedDescription }
            try? result.write(to: log, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.preparing = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.preparationStatus = result
                self.scan()
            }
        }
    }

    // A tap in Local Games: the game runs in MacShack Play (host/ShackPlayMac.m), prepared for Play first when needed.
    // When it ends, its log may name a fix (auto-config).
    func launch(_ url: URL) {
        guard !busy else { return }
        guard WindowsSetup.playInstalled else { error = ShackPlayMissing; return }
        AutoConfig.prepare(game: url)   // remembered/known launch arguments, before Play reads the .args
        let name = displayName(url)
        error = nil
        preparing = true
        preparationStatus = "Starting \(name) in MacShack Play…"
        DispatchQueue.global(qos: .userInitiated).async {
            ShackPlayMacRun(name, 0, 1) { _ in DispatchQueue.main.async { self.checkConfig(url) } }
            DispatchQueue.main.async { self.preparing = false; self.preparationStatus = "" }
        }
    }

    // Built-in JIT for this process (`--jit-spike`; games get it in MacShack Play): the MacShackJIT extension attaches
    // while ShackJITPoolSetup waits (loopback VPN on, pairing file imported).
    static var hasPairingFile: Bool { FileManager.default.fileExists(atPath: ShackJITPairingFileURL().path) }

    func startJITHelper() {
        jitStatus = "Enabling JIT… Keep LocalDevVPN connected."
        ShackJITHelperStart { ok, log in
            try? log.write(to: Self.logs.appendingPathComponent("jit-helper.log"), atomically: true, encoding: .utf8)
            guard !ok else { return }
            self.jitStatus = "JIT failed: \(log.split(separator: "\n").last ?? "unknown error"). Full log: Settings > Advanced > Logs > jit-helper.log."
        }
    }

    func importPairingFile(_ data: Data) {
        let url = ShackJITPairingFileURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            jitStatus = "Pairing file imported. JIT games now start without StikDebug."
            pairingReady = Self.hasPairingFile
        } catch { jitStatus = error.localizedDescription }
    }

    // Out of Local Games without deleting anything: Documents/Games/<Name>.app (+ .args) -> Documents/Archive.
    // Move it back with Files ("On My iPhone > MacShack") to restore.
    func archive(_ url: URL) {
        let fm = FileManager.default
        let dest = Self.documents.appendingPathComponent("Archive", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: url, to: dest.appendingPathComponent(url.lastPathComponent))
            let side = url.deletingPathExtension().appendingPathExtension("args")
            try? fm.moveItem(at: side, to: dest.appendingPathComponent(side.lastPathComponent))
        } catch { NSLog("[MacShack] archive %@: %@", url.lastPathComponent, "\(error)") }
        scan()
    }

    // For good: the .app (staged or installed), its .args, its prepared code in Library/Guests/<Name> and MacShack
    // Play's copy. Saves (Library/Application Support, Preferences) stay, so preparing the game again continues.
    func delete(_ url: URL) {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
        let games = Self.documents.appendingPathComponent("Games", isDirectory: true)
        let guests = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Guests/\(name)")
        for item in [url, guests, games.appendingPathComponent("\(name).args")]
            where fm.fileExists(atPath: item.path) {
            do { try fm.removeItem(at: item) } catch { NSLog("[MacShack] delete %@: %@", item.path, "\(error)") }
        }
        Self.forgetPlayCopy(name, code: true)
        scan()
    }

    // MacShack Play's copy of a Local Games game in the App Group (host/ShackPlayMac.m): its data, cloned at its first
    // start, and its code prepared for Play. A new import drops the data (the next start clones the new one); a delete
    // drops both (once the original is gone, the clone holds all of its space).
    nonisolated static func forgetPlayCopy(_ name: String, code: Bool) {
        guard let group = ShackHomeGroup() else { return }
        for item in ["Games/\(name).app", "Games/\(name).args"] + (code ? ["Guests/Play.\(name)"] : []) {
            try? FileManager.default.removeItem(atPath: "\(group)/\(item)")
        }
    }

    func checkConfig(_ url: URL) {
        guard let log = try? String(contentsOf: logURL(for: url), encoding: .utf8) else { return }
        let rules = AutoConfig.diagnose(log: log, current: AutoConfig.currentArgs(game: url))
        if !rules.isEmpty { configOffer = (url, rules) }
    }

    // Adds the fix and starts the game again.
    func applyConfig() {
        guard let offer = configOffer else { return }
        configOffer = nil
        AutoConfig.apply(offer.rules, game: offer.game)
        launch(offer.game)
    }

    func logURL(for url: URL) -> URL {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let exe = info?["CFBundleExecutable"] as? String ?? url.deletingPathExtension().lastPathComponent
        return Self.logs.appendingPathComponent("\(exe).log")
    }

    // A development identity is imported and matches this install's profile (ShackSigner checks both).
    static var identityValid: Bool { (try? ShackSigner.signingContext()) != nil }

    // A signing .p12 or a JIT pairing file, from AirDrop / "Open in" (MacShackApp's onOpenURL) or a Files picker
    // (onboarding, Settings > JIT & signing). A copy iOS put in Documents/Inbox is deleted once read: a private key must
    // not stay in the folder Files shows. Contents are never logged.
    func receive(_ url: URL) {
        if url.host == "windows-games" { openPage = .windowsGames; return }   // from MacShack Play's own screen
        guard url.isFileURL else { return }   // MacShack Play's return URL comes here too
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = (try? FileHandle(forReadingFrom: url)).flatMap { file -> Data? in
            defer { try? file.close() }
            return try? file.read(upToCount: 5_242_881)
        } ?? Data()
        let inbox = Self.documents.appendingPathComponent("Inbox").resolvingSymlinksInPath().path + "/"
        if url.resolvingSymlinksInPath().path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
        switch url.pathExtension.lowercased() {
        case "p12", "pfx":
            guard (1...1_048_576).contains(data.count) else { signingStatus = "The .p12 must be a nonempty file of at most 1 MB."; return }
            pendingCertificate = data
            askPassword = true
        case "plist", "mobiledevicepairing":
            guard (128...5_242_880).contains(data.count),
                  (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
                jitStatus = "That is not a pairing file."
                return
            }
            importPairingFile(data)
        default:
            jitStatus = "Not a certificate or a pairing file."
        }
    }

    // The prompt's Import: ShackSigner refuses a wrong password or another team's identity with its own words, and
    // keeps the old identity then. A good one is proven at once by signing and loading the test library.
    func importPendingCertificate(password: String) {
        guard let data = pendingCertificate else { return }
        pendingCertificate = nil
        do { try ShackSigner.importCertificate(data: data, password: password) }
        catch { signingStatus = error.localizedDescription; return }
        runSigningProof()
    }

    func runSigningProof() {
        signingBusy = true
        signingStatus = "Signing test library on device..."
        let log = Self.logs.appendingPathComponent("on-device-signing.log")
        DispatchQueue.global().async {
            let result: (report: String, ok: Bool)
            do { result = (try ShackSigner.runProbe(), true) } catch { result = (error.localizedDescription, false) }
            try? result.report.write(to: log, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.signingStatus = result.report
                self.signingBusy = false
                self.certificateReady = result.ok   // onboarding's check follows the latest probe
            }
        }
    }

    // The macOS Steam client is set up on this device: by SteamSetup, or copied by hand and prepared by --steam-load-probe.
    static var steamClientReady: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Guests/SteamClient/Steam/Contents/MacOS/steam_osx")
    }

    // The Steam client as the running guest (the first screen's Big Picture, or --steam-run). The island menu works over
    // Big Picture and over the games Steam starts.
    func launchSteamClient(arguments: [String]) {
        guard !launched else { return }
        launched = true
        hostRoot = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController
        GameOverlay.show()
        do { try ShackLoader.launchSteamClient(withArguments: arguments) }
        catch let failure {
            NSLog("[MacShack] the Steam client did not start: %@", failure.localizedDescription)
            error = failure.localizedDescription
            launched = false
            GameOverlay.hide()
        }
    }

    func openBigPicture() { launchSteamClient(arguments: ["-gamepadui"]) }

    // devicectl testing hooks.
    func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--metal4-fx-probe") {
            guard !autoLaunched else { return }
            autoLaunched = true
            // A fresh process exercises the native provider before guest hooks.
            DispatchQueue.global().async { ShackMetalFXProbe() }
            return
        }
        scan()
        // MacShack Play (host/ShackPlay.m): `--play-probe [minutes]` (the bridge checks), `--play-core [seconds]` (the checks for
        // Mac games in Play) or `--play-run <exe> [--play-jit MB]
        // [--play-seconds N] [--play-screen WxH] [--play-hud]` (a Windows program in Play); beside --steam-run they wait
        // for Big Picture to be up.
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var play: (mode: String, query: [String: String])?
        if args.contains("--play-probe") { play = ("probe", ["minutes": value("--play-probe").flatMap { UInt($0) }.map(String.init) ?? "10"]) }
        if args.contains("--play-core") { play = ("core", ["seconds": value("--play-core").flatMap { UInt($0) }.map(String.init) ?? "30"]) }
        // `--play-mac <Name> [--play-mac-seconds N] [--play-mac-runs N]`: an installed Local Games game in MacShack Play
        // (host/ShackPlayMac.m), asked to quit after N seconds, N times in a row.
        if let name = value("--play-mac") {
            let seconds = value("--play-mac-seconds").flatMap { UInt($0) } ?? 0, runs = value("--play-mac-runs").flatMap { UInt($0) } ?? 1
            AutoConfig.prepare(game: Self.documents.appendingPathComponent("Games/\(name).app"))   // known launch arguments, as for a launch here
            DispatchQueue.global().async { ShackPlayMacRun(name, seconds, max(runs, 1), nil) }
        }
        if let exe = value("--play-run") {
            var query = ["exe": exe]
            for (flag, key) in [("--play-jit", "jitMB"), ("--play-seconds", "seconds"), ("--play-screen", "screen")] {
                if let v = value(flag) { query[key] = v }
            }
            if args.contains("--play-hud") || UserDefaults.standard.bool(forKey: "metalHUD") { query["hud"] = "1" }
            play = ("run", query)
        }
        if let play {
            DispatchQueue.global().asyncAfter(deadline: .now() + (args.contains("--steam-run") ? 60 : 0)) { ShackPlayStart(play.mode, play.query, nil) }
        }
        // Beside --steam-run, Play logs on to this Steam: `--play-steam [seconds]` with Valve's steamclient itself,
        // `--play-steam-wine [seconds]` from a Windows program through lsteamclient (windows-kit); `--play-appid N`,
        // `--play-steam-via steamclient64|lsteamclient` (default: Valve's DLL, as a game loads it), `--play-steam-shim` (started
        // by NotProton's steam.exe, as a Steam game is), `--play-winedebug <WINEDEBUG>`.
        for (flag, wine) in [("--play-steam", false), ("--play-steam-wine", true)] where args.contains(flag) {
            let seconds = value(flag).flatMap { UInt($0) }.map(String.init) ?? "30", appid = value("--play-appid") ?? "480"
            let via = value("--play-steam-via") ?? "steamclient64"   // or "lsteamclient": the DLL straight, no detour
            let query = wine ? ["exe": "steamapi-test.exe", "args": "\(appid) \(seconds) \(via)", "steam": "1", "result": "steamapi-test.txt",
                                "shim": args.contains("--play-steam-shim") ? "1" : "", "appid": appid,
                                "winedebug": value("--play-winedebug") ?? ""]
                             : ["seconds": seconds, "appid": appid]
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { ShackSteamPlaySteamProbe(wine ? "run" : "steam", query) }
        }
        guard !autoLaunched else { return }
        if args.contains("--jit-spike") {
            autoLaunched = true; DispatchQueue.global().async { ShackJITSpike() }
            if Self.hasPairingFile { startJITHelper() }   // else attach StikDebug by hand
            return
        }
        if args.contains("--sign-probe") { autoLaunched = true; DispatchQueue.global().async { ShackSignProbe() }; return }
        // `--steam-setup [latest]`: Set up Steam without tapping (Documents/Logs/steam-setup.log); Steam does
        // not start.
        if let i = args.firstIndex(of: "--steam-setup") {
            autoLaunched = true
            if i + 1 < args.count, args[i + 1] == "latest" { SteamSetup.lockTested = false; steamSetup.start(.update) }
            else { steamSetup.start(.open) }
            return
        }
        // Prepare a hand-copied macOS Steam client and dlopen each image (Documents/Logs/steam-load.log).
        if args.contains("--steam-load-probe") { autoLaunched = true; DispatchQueue.global().async { ShackSteamLoadProbe() }; return }
        // The prepared macOS Steam client, started like a game (Documents/Logs/steam_osx.log,
        // Steam's own logs in Library/Application Support/Steam/logs). Arguments after --steam-run go to steam_osx.
        if let i = args.firstIndex(of: "--steam-run") {
            autoLaunched = true
            launchSteamClient(arguments: Array(args[(i + 1)...]))
            return
        }
        if args.contains("--on-device-sign-probe") { autoLaunched = true; runSigningProof(); return }
        if let i = args.firstIndex(of: "--prepare"), i + 1 < args.count,
           let url = (staged + games).first(where: { $0.deletingPathExtension().lastPathComponent == args[i + 1] }) {
            autoLaunched = true; prepare(url); return
        }
        if let i = args.firstIndex(of: "--launch"), i + 1 < args.count,
           let url = games.first(where: { $0.deletingPathExtension().lastPathComponent == args[i + 1] }) {
            autoLaunched = true; launch(url)
        }
    }
}
