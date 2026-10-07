import SwiftUI
import UIKit

// Valve's macOS Steam client set up on this device from Valve's CDN (prep/steam-onehost/README.md,
// "Setup on the device"): the pinned (or latest) manifest; the changed packages downloaded
// into a cache, checked and unpacked into a staging copy; that copy prepared and signed into a new code folder; then both
// swapped in, the only moment the live Steam changes. Steam's own data beside Steam.AppBundle (config, userdata,
// steamapps, logs, sign-in) is never touched. Log: Documents/Logs/steam-setup.log.
@Observable
@MainActor
final class SteamSetup {
    enum Mode: String, Identifiable {
        case open     // Big Picture: install, or move to the wanted version; with a Steam here, a failure boots that one
        case update   // Steam settings: Valve's latest
        case repair   // Steam settings: every package and the prepare again
        var id: Self { self }
    }
    enum State: Equatable { case idle, checking, downloading(Int64, Int64), preparing(Int, Int), done, failed(String) }

    var state: State = .idle
    var offerLatest = false   // the tested version is gone from Valve's CDN: the failure offers latest instead
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    // Bumped when Steam's prepare changes (ShackSteamPrepare): a stamp with another value prepares again, no download.
    static let prepVersion = 1
    static let cdn = URL(string: "https://client-update.fastly.steamstatic.com/")!
    // Where the macos-signed-2 steam_osx keeps its install's manifest, as on a Mac.
    static let manifestName = "steam_client_signed-2_osx.manifest"
    // Resolved at launch (init): once a game or Steam has run, Bundle.main answers for that guest (identity hooks).
    private static let pinURL = Bundle.main.url(forResource: "steam_client_osx", withExtension: "manifest")
    static var pin: SteamClientManifest? { pinURL.flatMap { SteamClientManifest(contentsOf: $0) } }

    init() { _ = Self.pinURL }
    // On by default: setup installs the Steam this MacShack was tested with. Update to latest turns it off.
    static var lockTested: Bool {
        get { UserDefaults.standard.object(forKey: "steamClient.lockTested") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "steamClient.lockTested") }
    }

    private enum Paths {
        static let home = URL(fileURLWithPath: NSHomeDirectory())
        static let bundle = home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle")   // Steam/Contents/…
        static let staging = home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle.new")
        static let guest = home.appendingPathComponent("Library/Guests/SteamClient")   // prepared code: Steam/Contents/…, stamp.plist
        static let guestNew = home.appendingPathComponent("Library/Guests/SteamClient.new")
        static let cache = home.appendingPathComponent("Library/Caches/SteamSetup")
        static func contents(_ root: URL) -> URL { root.appendingPathComponent("Steam/Contents") }
    }

    struct Stamp: Codable { var version: String; var latest: Bool; var prep: Int }
    static var stamp: Stamp? {
        (try? Data(contentsOf: Paths.guest.appendingPathComponent("stamp.plist"))).flatMap { try? PropertyListDecoder().decode(Stamp.self, from: $0) }
    }

    // Big Picture can start as it is: copied by hand (no stamp: setup never replaces it on its own), or set up at the
    // tested version with today's prepare while locked. Unlocked (latest) goes through setup, which asks Valve first.
    static var isCurrent: Bool {
        guard AppModel.steamClientReady else { return false }
        guard let stamp else { return true }
        return lockTested && stamp.version == pin?.version && stamp.prep == prepVersion
    }

    // Steam settings: what is installed.
    static var installedLabel: String {
        guard AppModel.steamClientReady else { return "Not set up" }
        guard let stamp else { return "Copied by hand" }
        let date = Date(timeIntervalSince1970: TimeInterval(stamp.version) ?? 0).formatted(date: .abbreviated, time: .omitted)
        return "\(date), \(stamp.latest ? "latest" : "tested")"
    }

    func start(_ mode: Mode) {
        if let task, !task.isCancelled { return }   // already running
        let previous = task   // a cancelled run still finishing its current step (a hash, an unzip)
        generation += 1
        let mine = generation
        offerLatest = false
        state = .checking
        let hadSteam = AppModel.steamClientReady
        task = Task {
            await previous?.value
            UIApplication.shared.isIdleTimerDisabled = true   // the screen stays on while setup runs
            let outcome: State
            do {
                try await install(mode)
                outcome = .done
            } catch {
                if Task.isCancelled {
                    log("cancelled")
                    outcome = .idle
                } else {
                    log("failed: \(error.localizedDescription)")
                    // Big Picture with a Steam already here and Valve unreachable (offline, CDN failing): that Steam
                    // boots. Any other failure is shown.
                    let offline = error is URLError || (error as? SteamSetupError)?.offline == true
                    outcome = mode == .open && hadSteam && offline ? .done : .failed(error.localizedDescription)
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            guard generation == mine else { return }   // a newer run owns state and task
            state = outcome
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func install(_ mode: Mode) async throws {
        try Task.checkCancellation()   // a run cancelled while it waited for the previous one
        let fm = FileManager.default
        log("setup (\(mode.rawValue)) started")
        do { _ = try ShackSigner.signingContext() } catch {
            throw SteamSetupError(error.localizedDescription)   // the signer's own words, as onboarding's certificate page shows them
        }
        let latest = mode == .update || !Self.lockTested
        let wanted = try await manifest(latest: latest)
        let installedURL = Paths.contents(Paths.bundle).appendingPathComponent("MacOS/package/\(Self.manifestName)")
        let installed = mode == .repair ? nil : SteamClientManifest(contentsOf: installedURL)
        let changed = wanted.changed(since: installed)
        // An interrupted run's leftovers first: they would count against the free space, and an up-to-date Steam needs none.
        await offMain {
            for leftover in [Paths.staging, Paths.guestNew, Paths.bundle.appendingPathExtension("old"), Paths.guest.appendingPathExtension("old")] {
                try? FileManager.default.removeItem(at: leftover)
            }
        }
        if changed.isEmpty, AppModel.steamClientReady, let stamp = Self.stamp, stamp.version == wanted.version, stamp.prep == Self.prepVersion {
            log("Steam \(wanted.version) is up to date")
            return
        }
        try checkSpace(installed == nil ? 3_000_000_000 : 1_500_000_000)

        // Staging: a clone of the installed tree (APFS: instant, no space; also on Repair, which unpacks every package over
        // it but keeps what Steam wrote inside its bundle), or empty.
        if fm.fileExists(atPath: Paths.bundle.path) { try await offMainThrowing { try FileManager.default.copyItem(at: Paths.bundle, to: Paths.staging) } }
        let contents = Paths.contents(Paths.staging), macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        // Packages: kept when a verified copy is in the cache (a cancelled run resumes there), unpacked into staging.
        try fm.createDirectory(at: Paths.cache, withIntermediateDirectories: true)
        let total = changed.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for package in changed {
            try Task.checkCancellation()
            let zip = Paths.cache.appendingPathComponent(package.file)
            try await fetch(package, to: zip, base: done, total: total, latest: latest)
            done += package.size
            state = .downloading(done, total)
            if let failure = await offMain({ ShackSteamUnzip(zip.path, macOS.path) }) { throw SteamSetupError("\(package.name): \(failure)") }
            log("\(package.name) unpacked")
        }

        // Steam.app's own files (a first install, or a new bootstrapper), Contents/Frameworks as on a Mac, Valve's switch
        // that keeps the client from updating itself, and the manifest Steam reads as its install.
        if installed == nil || changed.contains(where: { $0.name == "appdmg_osx" }) {
            let tar = macOS.appendingPathComponent("SteamMacBootstrapper.tar.gz")
            if let failure = await offMain({ ShackSteamUnpackSkeleton(tar.path, contents.path) }) { throw SteamSetupError("Steam.app: \(failure)") }
        }
        let frameworks = contents.appendingPathComponent("Frameworks")
        if (try? fm.destinationOfSymbolicLink(atPath: frameworks.path)) == nil {
            try? fm.removeItem(at: frameworks)
            try fm.createSymbolicLink(atPath: frameworks.path, withDestinationPath: "MacOS/Frameworks")
        }
        try Data("BootStrapperInhibitAll=enable\n".utf8).write(to: macOS.appendingPathComponent("steam.cfg"))
        try fm.createDirectory(at: macOS.appendingPathComponent("package"), withIntermediateDirectories: true)
        try wanted.data.write(to: macOS.appendingPathComponent("package/\(Self.manifestName)"))

        // Prepared and signed from staging into a new code folder; the live Steam is still as it was.
        try Task.checkCancellation()
        state = .preparing(0, 0)
        let source = Paths.staging.appendingPathComponent("Steam").path, guest = Paths.guestNew.appendingPathComponent("Steam").path
        let failed: [String] = await offMain {
            ShackSteamPrepare(source, guest, nil) { done, total in
                Task { @MainActor in self.state = .preparing(Int(done), Int(total)) }
            } ?? []
        }
        guard failed.isEmpty else { throw SteamSetupError("Steam did not prepare: \(failed.prefix(3).joined(separator: "; "))") }
        try PropertyListEncoder().encode(Stamp(version: wanted.version, latest: latest, prep: Self.prepVersion))
            .write(to: Paths.guestNew.appendingPathComponent("stamp.plist"))

        // The swap: data and code together.
        try swap(Paths.staging, into: Paths.bundle)
        try swap(Paths.guestNew, into: Paths.guest)
        await offMain {
            for finished in [Paths.bundle.appendingPathExtension("old"), Paths.guest.appendingPathExtension("old"), Paths.cache] {
                try? FileManager.default.removeItem(at: finished)
            }
        }
        log("Steam \(wanted.version) (\(latest ? "latest" : "tested")) set up, \(changed.count) packages")
    }

    // The pin bundled with MacShack, or Valve's live manifest.
    private func manifest(latest: Bool) async throws -> SteamClientManifest {
        if !latest {
            guard let pin = Self.pin else { throw SteamSetupError("This build has no pinned Steam manifest (host/steam_client_osx.manifest).") }
            return pin
        }
        let (data, response) = try await URLSession.shared.data(from: Self.cdn.appendingPathComponent("steam_client_osx"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, let live = SteamClientManifest(data: data) else {
            throw SteamSetupError("Valve's Steam manifest did not load. Check the connection and tap Retry.", offline: true)
        }
        return live
    }

    // A package into the cache: kept when a verified copy is there, else downloaded and checked (sha256), one retry.
    // A file of the tested version Valve no longer serves (404) offers latest instead.
    private func fetch(_ package: SteamClientManifest.Package, to zip: URL, base: Int64, total: Int64, latest: Bool) async throws {
        for attempt in 0..<2 {
            if await offMain({ SteamClientManifest.sha256(of: zip) }) == package.sha2 { return }
            try Task.checkCancellation()
            log("downloading \(package.file)\(attempt > 0 ? " again" : "")")
            let status = try await download(Self.cdn.appendingPathComponent(package.file), to: zip) { [weak self] bytes in
                Task { @MainActor in self?.state = .downloading(base + bytes, total) }
            }
            if status == 404, !latest {
                offerLatest = true
                throw SteamSetupError("Valve no longer serves \(package.file) of the tested Steam.")
            }
            guard status == 200 else { throw SteamSetupError("\(package.file): HTTP \(status)", offline: true) }
        }
        if await offMain({ SteamClientManifest.sha256(of: zip) }) == package.sha2 { return }
        try? FileManager.default.removeItem(at: zip)
        throw SteamSetupError("\(package.name) arrived damaged twice (sha256). Tap Retry.")
    }

    // One file into `to`, reporting bytes as they come (each MB); returns the HTTP status (the file is kept only on 200).
    private func download(_ url: URL, to: URL, progress: @escaping (Int64) -> Void) async throws -> Int {
        let box = DownloadBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Int, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    box.observation = nil
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    do {
                        if let error { throw error }
                        if status == 200, let file {
                            try? FileManager.default.removeItem(at: to)
                            try FileManager.default.moveItem(at: file, to: to)
                        }
                        finished.resume(returning: status)
                    } catch { finished.resume(throwing: error) }
                }
                box.observation = task.progress.observe(\.completedUnitCount) { p, _ in
                    guard p.completedUnitCount - box.reported >= 1 << 20 else { return }
                    box.reported = p.completedUnitCount
                    progress(p.completedUnitCount)
                }
                box.task = task
                task.resume()
            }
        } onCancel: { box.task?.cancel() }
    }

    private func checkSpace(_ needed: Int64) throws {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= needed else {
            throw SteamSetupError(String(format: "Steam needs %.1f GB free; this device has %.1f GB.", Double(needed) / 1e9, Double(free) / 1e9))
        }
    }

    // `new` replaces `live`: live moves aside to .old, new takes its name; if that fails, live comes back. The .old
    // copies are removed afterwards, off the main thread.
    private func swap(_ new: URL, into live: URL) throws {
        let fm = FileManager.default, old = live.appendingPathExtension("old")
        if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: old) }
        do { try fm.moveItem(at: new, to: live) } catch { try? fm.moveItem(at: old, to: live); throw error }
    }

    // Hashing, unpacking and preparing run off the main thread.
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func offMainThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func log(_ line: String) {
        NSLog("[SteamSetup] %@", line)
        let url = AppModel.logs.appendingPathComponent("steam-setup.log"), text = Data("\(Date()) \(line)\n".utf8)
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: text)
        } else {
            try? text.write(to: url)
        }
    }
}

// The running download, for cancellation and progress (set before the task starts).
private final class DownloadBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var observation: NSKeyValueObservation?
    var reported: Int64 = 0
}

private struct SteamSetupError: LocalizedError {
    let errorDescription: String?
    var offline = false   // Valve unreachable or failing: Big Picture boots the Steam already here
    init(_ message: String, offline: Bool = false) { errorDescription = message; self.offline = offline }
}

// Setup's progress: full screen from the first screen or Settings, or inside onboarding's Steam page. Starts setup when it appears.
struct SteamSetupView: View {
    @Environment(AppModel.self) private var app
    let mode: SteamSetup.Mode
    let done: () -> Void    // set up: Big Picture next
    let close: () -> Void   // cancelled, or given up after a failure

    var body: some View {
        let setup = app.steamSetup
        VStack(spacing: 16) {
            Text(title(setup.state)).font(.title2.weight(.semibold))
            if let fraction = progressFraction(setup.state) {
                ProgressView(value: min(fraction, 1)).frame(maxWidth: 420)
            } else if case .failed = setup.state {
                EmptyView()
            } else {
                ProgressView()
            }
            if case .failed(let message) = setup.state {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                HStack(spacing: 12) {
                    Button("Retry") { setup.start(mode) }.buttonStyle(.borderedProminent)
                    if setup.offerLatest {
                        Button("Install latest instead (untested)") { SteamSetup.lockTested = false; setup.start(.update) }
                            .buttonStyle(.bordered)
                    }
                    if mode == .open && AppModel.steamClientReady {
                        Button("Start the installed Steam") { setup.state = .idle; done() }.buttonStyle(.bordered)
                    }
                    Button("Close", action: close).buttonStyle(.bordered)
                }
            } else if case .preparing = setup.state {
                Text("Keep MacShack open while Steam is prepared.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Cancel") { setup.cancel(); close() }.buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { setup.start(mode) }
        .onChange(of: setup.state) { _, state in
            if state == .done { setup.state = .idle; done() }
        }
    }

    private func title(_ state: SteamSetup.State) -> String {
        switch state {
        case .idle, .checking: "Checking Steam…"
        case .downloading(let done, let total): "Downloading Steam… \(done / 1_000_000) of \(total / 1_000_000) MB"
        case .preparing(let done, let total): total > 0 ? "Preparing Steam… \(done) of \(total)" : "Preparing Steam…"
        case .done: "Steam is ready"
        case .failed: "Steam setup stopped"
        }
    }

    private func progressFraction(_ state: SteamSetup.State) -> Double? {
        switch state {
        case .downloading(let done, let total) where total > 0: Double(done) / Double(total)
        case .preparing(let done, let total) where total > 0: Double(done) / Double(total)
        default: nil
        }
    }
}
