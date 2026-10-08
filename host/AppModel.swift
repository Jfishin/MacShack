import SwiftUI
import UIKit

// Local state behind the launcher, Local Games and Settings: what is in Documents/Staging and Documents/Games, the
// on-device prepare, launching (one attempt per process: the loader's hooks are process-wide), and the signing identity.
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
    @ObservationIgnored private var current: (url: URL, exe: String)?
    @ObservationIgnored private var jitFailure: String?   // the helper's reason, kept past the loader's generic timeout
    var error: String?
    var launched = false
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
    var currentGame: String?
    var ended: String?   // the game that quit: MacShack is back, and another game needs a fresh process
    var configOffer: (game: URL, rules: [AutoConfig.Rule])?   // Local Games asks to set up auto-config (AutoConfig.swift)
    var stalePrepare: (url: URL, reason: String)?   // Local Games asks to prepare it again: the loader refused its prepared code
    @ObservationIgnored private var hostRoot: UIViewController?

    var busy: Bool { (launched && ended == nil) || preparing || signingBusy }

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
        NotificationCenter.default.addObserver(forName: Notification.Name("ShackGuestLaunchFailed"), object: nil, queue: .main) { [weak self] note in
            let message = note.userInfo?["message"] as? String
            MainActor.assumeIsolated {
                GameOverlay.hide()
                self?.error = [self?.jitFailure, message].compactMap { $0 }.joined(separator: "\n")
                self?.jitStatus = "Launch stopped. Close and reopen MacShack before retrying."
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("ShackJITReady"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.jitStatus = "JIT is ready. Starting the game…" }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("ShackGuestExited"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameEnded() }
        }
    }

    // The game quit (or its main returned): MacShack's own screen comes back. Another game needs a fresh process.
    private func gameEnded() {
        guard launched, ended == nil else { return }
        GameOverlay.hide()
        if let root = hostRoot, let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first {
            window.rootViewController = root
            root.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        ended = currentGame ?? "The game"
        jitStatus = ""
        scan()
        UserDefaults.standard.removeObject(forKey: "lastLaunch")
        if let current { checkConfig(current.url) }
    }

    func scan() {
        guard !preparing && (!launched || ended != nil) else { return }
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

    // `then` gets (success, message); the stale-prepare alert uses it to launch after a successful prepare.
    func prepare(_ url: URL, then done: ((Bool, String) -> Void)? = nil) {
        guard !busy else { done?(false, "MacShack is busy."); return }
        preparing = true
        error = nil
        preparationStatus = "Preparing \(url.deletingPathExtension().lastPathComponent)…"
        UIApplication.shared.isIdleTimerDisabled = true
        let path = url.path, log = Self.logs.appendingPathComponent("preparation.log")
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String, ok: Bool
            do { result = try ShackInstaller.installApp(atPath: StagedFolder.unpack(URL(fileURLWithPath: path), staging: Self.documents.appendingPathComponent("Staging"), games: Self.documents.appendingPathComponent("Games")).path); ok = true }
            catch { result = error.localizedDescription; ok = false }
            try? result.write(to: log, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.preparing = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.preparationStatus = result
                self.scan()
                done?(ok, result)
            }
        }
    }

    func launch(_ url: URL) {
        guard !ProcessInfo.processInfo.arguments.contains("--metal4-fx-probe") else {
            error = "MetalFX probe process: close and reopen MacShack before launching a game."
            return
        }
        if ended != nil {   // one game per process: remember the pick, and MacShack reopens straight into it
            UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent, forKey: "pendingLaunch")
            ShackExitProcess(0)
            return
        }
        guard !launched else { return }
        AutoConfig.prepare(game: url)   // remembered/known launch arguments, before the loader reads the .args
        UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent, forKey: "lastLaunch")   // cleared when it ends
        let needsJIT = ShackInstaller.requiresJIT(atAppPath: url.path)
        let hostID = Bundle.main.bundleIdentifier ?? ""
        do { try ShackLoader.validateApp(atPath: url.path) }   // before the loader installs process-wide hooks
        catch { stalePrepare = (url, error.localizedDescription); return }   // Local Games offers Prepare again
        launched = true
        currentGame = displayName(url)
        hostRoot = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController
        GameOverlay.show(game: url, app: self)
        let exe = Self.executable(of: url)
        current = (url, exe)
        Task {
            if let id = Self.appID(for: url) {
                // Valve's own Steam library: with no steam_appid.txt in the working directory,
                // SteamAPI_RestartAppIfNecessary asks Steam to relaunch the game and the game quits (Akane).
                // It reads the file from the working directory, which Unity changes; Steam's own launch variables too.
                try? "\(id)".write(to: url.appendingPathComponent("Contents/MacOS/steam_appid.txt"), atomically: true, encoding: .utf8)
                setenv("SteamAppId", "\(id)", 1)
                setenv("SteamGameId", "\(id)", 1)
            }
            startGame(url, needsJIT: needsJIT, hostID: hostID)
        }
    }

    // A game's Steam app ID: steam_appid.txt in the bundle.
    private static func appID(for game: URL) -> UInt32? {
        for file in [game.appendingPathComponent("Contents/MacOS/steam_appid.txt"),
                     game.appendingPathComponent("Contents/Resources/steam_appid.txt")] {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let id = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 { return id }
        }
        return nil
    }

    private func startGame(_ url: URL, needsJIT: Bool, hostID: String) {
        // Read by Metal when the game creates its device, which happens after this.
        if UserDefaults.standard.bool(forKey: "metalHUD") { setenv("MTL_HUD_ENABLED", "1", 1) }
        do {
            try ShackLoader.launchApp(atPath: url.path)
            guard needsJIT else { return }
            if Self.hasPairingFile { startJITHelper(); return }
            jitStatus = "In StikDebug, tap Enable Script. Keep the phone unlocked and its loopback VPN active. Return to MacShack after the script finishes."
            var link = URLComponents()
            link.scheme = "stikjit"; link.host = "enable-jit"
            link.queryItems = [URLQueryItem(name: "bundle-id", value: hostID),
                               URLQueryItem(name: "pid", value: String(ProcessInfo.processInfo.processIdentifier)),
                               URLQueryItem(name: "script-name", value: "macshack-jit.js")]
            if let stik = link.url {
                UIApplication.shared.open(stik) { opened in
                    if !opened { self.jitStatus = "Could not open StikDebug. Install it and add macshack-jit.js, then reopen MacShack to retry." }
                }
            }
        } catch {
            GameOverlay.hide()
            self.error = "\(error)"
            NSLog("[MacShack] launch failed: %@", "\(error)")   // stderr is the game log by now
        }
    }

    // Built-in JIT: the MacShackJIT extension attaches to this process while ShackJITPoolSetup waits (loopback VPN
    // on, pairing file imported). No fallback to StikDebug after a failure: the error says what to fix.
    static var hasPairingFile: Bool { FileManager.default.fileExists(atPath: ShackJITPairingFileURL().path) }

    func startJITHelper() {
        jitStatus = "Enabling JIT… Keep LocalDevVPN connected."
        ShackJITHelperStart { ok, log in
            try? log.write(to: Self.logs.appendingPathComponent("jit-helper.log"), atomically: true, encoding: .utf8)
            guard !ok else { return }
            self.jitFailure = "JIT failed: \(log.split(separator: "\n").last ?? "unknown error"). Full log: Settings > Advanced > Logs > jit-helper.log."
            self.jitStatus = self.jitFailure ?? ""
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

    // For good: the .app (staged or installed), its .args and its prepared code in Library/Guests/<Name>.
    // Saves (Library/Application Support, Preferences) stay, so preparing the game again continues.
    func delete(_ url: URL) {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent
        let games = Self.documents.appendingPathComponent("Games", isDirectory: true)
        let guests = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Guests/\(name)")
        for item in [url, guests, games.appendingPathComponent("\(name).args")]
            where fm.fileExists(atPath: item.path) {
            do { try fm.removeItem(at: item) } catch { NSLog("[MacShack] delete %@: %@", item.path, "\(error)") }
        }
        scan()
    }

    func checkConfig(_ url: URL) {
        guard let log = try? String(contentsOf: logURL(for: url), encoding: .utf8) else { return }
        let rules = AutoConfig.diagnose(log: log, current: AutoConfig.currentArgs(game: url))
        if !rules.isEmpty { configOffer = (url, rules) }
    }

    // Adds the fix and starts the game again (launch() reopens MacShack into it when this process already ran one).
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
        currentGame = "Steam"
        hostRoot = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.rootViewController
        GameOverlay.show(game: nil, name: "Steam", app: self)
        do { try ShackLoader.launchSteamClient(withArguments: arguments) }
        catch let failure {
            NSLog("[MacShack] the Steam client did not start: %@", failure.localizedDescription)
            error = failure.localizedDescription
            launched = false
            currentGame = nil
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
        // The last game never ended cleanly (it crashed MacShack): its log may name a fix.
        if let last = UserDefaults.standard.string(forKey: "lastLaunch") {
            UserDefaults.standard.removeObject(forKey: "lastLaunch")
            if let url = games.first(where: { $0.deletingPathExtension().lastPathComponent == last }) { checkConfig(url) }
        }
        // MacShack Play (host/ShackPlay.m): `--play-probe [minutes]` (the bridge checks) or `--play-run <exe> [--play-jit MB]
        // [--play-seconds N] [--play-screen WxH] [--play-hud]` (a Windows program in Play); beside --steam-run they wait
        // for Big Picture to be up.
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var play: (mode: String, query: [String: String])?
        if args.contains("--play-probe") { play = ("probe", ["minutes": value("--play-probe").flatMap { UInt($0) }.map(String.init) ?? "10"]) }
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
        if let pending = UserDefaults.standard.string(forKey: "pendingLaunch") {   // picked after the last game ended
            UserDefaults.standard.removeObject(forKey: "pendingLaunch")
            if let url = games.first(where: { $0.deletingPathExtension().lastPathComponent == pending }) { autoLaunched = true; launch(url); return }
        }
        if let i = args.firstIndex(of: "--launch"), i + 1 < args.count,
           let url = games.first(where: { $0.deletingPathExtension().lastPathComponent == args[i + 1] }) {
            autoLaunched = true; launch(url)
        }
    }
}
