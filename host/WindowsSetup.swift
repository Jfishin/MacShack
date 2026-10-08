import SwiftUI
import UIKit

// "Set up Windows games" (README, "Windows games"): Madeira's engine, MacShack's
// Windows kit and Valve's Windows files downloaded and checked, laid out in the App Group's Windows folder
// (WindowsKit.layOut), the libraries signed for MacShack Play, setup.json last. Steam Play follows at the next Steam
// start (ShackLoader.m, ShackWindowsGamesOn). Remove takes it out again. Log: Documents/Logs/windows-setup.log.
@Observable
@MainActor
final class WindowsSetup {
    enum State: Equatable { case idle, downloading(String, Int64), working(String), failed(String) }
    var state: State = .idle
    var restartNeeded = false   // Steam reads Steam Play's on/off only when it starts, which is when MacShack starts
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static var group: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShackPlayGroup(ShackPlayHostBundleID())) }
    static var root: URL? { group?.appendingPathComponent("Windows") }
    static var stamp: WindowsKit.Stamp? {
        root.flatMap { try? Data(contentsOf: $0.appendingPathComponent("setup.json")) }.flatMap { try? JSONDecoder().decode(WindowsKit.Stamp.self, from: $0) }
    }
    // MacShack Play answers its URL scheme (MacShack's Info.plist lists it under LSApplicationQueriesSchemes).
    static var playInstalled: Bool { URL(string: ShackPlayHostBundleID() + ".play://").map { UIApplication.shared.canOpenURL($0) } ?? false }
    private static let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/WindowsSetup")

    // Windows games in the MacShack Play library (Steam's appmanifest files) and the library's size: Remove's question.
    nonisolated static func installedGames() -> (count: Int, bytes: Int64) {
        guard let library = group?.appendingPathComponent("SteamLibrary") else { return (0, 0) }
        let fm = FileManager.default
        let count = (try? fm.contentsOfDirectory(atPath: library.appendingPathComponent("steamapps").path))?
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }.count ?? 0
        var bytes: Int64 = 0
        let walk = fm.enumerator(at: library, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let url = walk?.nextObject() as? URL {
            bytes += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return (count, bytes)
    }

    func start() {
        if task != nil { return }   // already running (task is cleared at the end of every run, a cancelled one included)
        state = .working("Checking")
        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true   // the screen stays on while setup runs
            do {
                try await install()
                log("set up: Madeira \(WindowsKit.madeiraVersion), kit \(WindowsKit.kitVersion)")
                restartNeeded = true
                state = .idle
            } catch {
                if Task.isCancelled { log("cancelled"); state = .idle }
                else { log("failed: \(error.localizedDescription)"); state = .failed(error.localizedDescription) }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func install() async throws {
        do { _ = try ShackSigner.signingContext() } catch { throw WindowsKit.Failure(error.localizedDescription) }
        guard let root = Self.root else { throw WindowsKit.Failure("MacShack has no App Group container: build it with project.yml's App Group.") }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= 2_000_000_000 else {
            throw WindowsKit.Failure(String(format: "Setting up Windows games needs 2 GB free; this device has %.1f GB.", Double(free) / 1e9))
        }
        let fm = FileManager.default, cache = Self.cache
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        for piece in WindowsKit.downloads { try await fetch(piece) }
        try Task.checkCancellation()   // a Cancel after the last download stops here, before anything is laid out
        state = .working("Unpacking")
        let new = root.appendingPathExtension("new")
        let old = root.appendingPathExtension("old")
        do {   // a failure anywhere from here leaves no partial Windows.new (about 1 GB)
            let libraries = try await offMainThrowing { try WindowsKit.layOut(cache: cache, into: new, unzip: { ShackSteamUnzip($0, $1) }) }
            guard !libraries.isEmpty else { throw WindowsKit.Failure("Madeira's engine has no libraries to sign.") }
            state = .working("Signing for MacShack Play")
            let identifier = ShackPlayHostBundleID() + ".play"
            try await offMainThrowing { for library in libraries { try Self.sign(library, as: identifier) } }
            try JSONEncoder().encode(WindowsKit.stamp).write(to: new.appendingPathComponent("setup.json"))
            // The swap: whatever was there aside, the new folder in.
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
            do { try fm.moveItem(at: new, to: root) } catch { try? fm.moveItem(at: old, to: root); throw error }
        } catch {
            await offMain { try? FileManager.default.removeItem(at: new) }
            throw error
        }
        // Then the old folder and the download cache go.
        await offMain { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: cache) }
    }

    // A download into the cache: kept when a verified copy is there (a copy put there by hand counts), else downloaded
    // and checked (sha256), one retry.
    private func fetch(_ piece: WindowsKit.Download) async throws {
        let file = Self.cache.appendingPathComponent(piece.file)
        for attempt in 0..<2 {
            if await offMain({ SteamClientManifest.sha256(of: file) }) == piece.sha256 { return }
            try Task.checkCancellation()
            log("downloading \(piece.url.absoluteString)\(attempt > 0 ? " again" : "")")
            state = .downloading(piece.name, 0)
            let status = try await download(piece.url, to: file) { [weak self] bytes in
                Task { @MainActor in self?.state = .downloading(piece.name, bytes) }
            }
            if status == 404 { throw WindowsKit.Failure("\(piece.name) is not available at \(piece.url.host ?? "its source") (HTTP 404).") }
            guard status == 200 else { throw WindowsKit.Failure("\(piece.name): HTTP \(status). Check the connection and tap Retry.") }
        }
        if await offMain({ SteamClientManifest.sha256(of: file) }) == piece.sha256 { return }
        try? FileManager.default.removeItem(at: file)
        throw WindowsKit.Failure("\(piece.name) arrived damaged twice (sha256). Tap Retry.")
    }

    // Signed beside, then renamed over: a new file, as iOS wants before dlopen (AGENTS.md).
    nonisolated private static func sign(_ library: URL, as identifier: String) throws {
        let fresh = library.appendingPathExtension("signed")
        try? FileManager.default.removeItem(at: fresh)
        try ShackSigner.signBinary(atPath: library.path, outputPath: fresh.path, identifier: identifier)
        guard rename(fresh.path, library.path) == 0 else { throw WindowsKit.Failure("\(library.lastPathComponent): \(String(cString: strerror(errno)))") }
    }

    // Remove Windows games: the Windows folder and the download cache now; Steam Play goes at the next Steam start
    // (ShackLoader.m). With deleteGames, the MacShack Play library too: its games and their prefixes (local saves).
    // Windows goes aside first (one rename): setup.json, which switches Steam Play on, is never left without the engine
    // if the app is killed mid-delete.
    func remove(deleteGames: Bool) {
        guard let root = Self.root, let group = Self.group else { return }
        state = .working("Removing")
        let cache = Self.cache
        Task {
            await offMain {
                let fm = FileManager.default, old = root.appendingPathExtension("old"), new = root.appendingPathExtension("new")
                try? fm.removeItem(at: old)
                if (try? fm.moveItem(at: root, to: old)) == nil {   // no rename possible: delete in place,
                    try? fm.removeItem(at: root.appendingPathComponent("setup.json"))   // setup.json first, so Steam Play never sees a half-deleted engine
                    try? fm.removeItem(at: root)
                }
                try? fm.removeItem(at: old)
                try? fm.removeItem(at: new)   // an interrupted setup's leftover
                try? fm.removeItem(at: cache)
                // Valve's macOS Steam images, re-signed for Play (ShackSteamPreparePlayFiles); the next Windows game launch makes them again.
                try? fm.removeItem(at: group.appendingPathComponent("SteamClient"))
                if deleteGames { try? fm.removeItem(at: group.appendingPathComponent("SteamLibrary")) }
            }
            log("removed\(deleteGames ? ", with the MacShack Play library" : ", the MacShack Play library kept")")
            restartNeeded = true
            state = .idle
        }
    }

    private func log(_ line: String) { appendLog(line, tag: "WindowsSetup", file: "windows-setup.log") }
}
