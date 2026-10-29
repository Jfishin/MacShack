import Foundation
import StikJIT

// MacShack's built-in JIT enabler: a hidden share extension that MacShack starts for its own PID
// (host/ShackJITHelper.m). A debugger client cannot live in MacShack itself: attaching suspends every thread of the
// target, the client's included. StikJIT connects through LocalDevVPN (10.7.0.1, RemotePairing's port) with the imported pairing
// file, mounts the Developer Disk Image when needed (cached in this extension's Library), attaches and runs our
// script, which prepares the RX pool ShackJITPoolSetup asks for and detaches. The log lines go back to MacShack in
// the completed request; a failure cancels the request with the error.
@objc(MacShackJITRequestHandler)
final class MacShackJITRequestHandler: NSObject, NSExtensionRequestHandling {
    static let requestType = "macshack.jit-request"
    private let queue = DispatchQueue(label: "macshack.jit-helper")   // StikJIT's calls block

    func beginRequest(with context: NSExtensionContext) {
        guard let provider = (context.inputItems.first as? NSExtensionItem)?.attachments?.first,
              provider.hasItemConformingToTypeIdentifier(Self.requestType) else {
            return context.cancelRequest(withError: Self.error("Missing JIT request."))
        }
        provider.loadItem(forTypeIdentifier: Self.requestType, options: nil) { item, error in
            if let error { return context.cancelRequest(withError: error) }
            guard let data = item as? Data else { return context.cancelRequest(withError: Self.error("Unreadable JIT request.")) }
            self.queue.async { self.run(data, context) }
        }
    }

    private func run(_ data: Data, _ context: NSExtensionContext) {
        var lines: [String] = []
        let note = { (line: String) in lines.append(line); NSLog("[MacShackJIT] %@", line) }
        let fm = FileManager.default
        let pairing = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? fm.removeItem(at: pairing) }
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (request["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let encoded = request["pairing"] as? String, let pairingData = Data(base64Encoded: encoded),
                  !pairingData.isEmpty,
                  let script = Bundle(for: Self.self).url(forResource: "macshack-jit", withExtension: "js") else {
                throw Self.error("Invalid JIT request.")
            }
            try pairingData.write(to: pairing, options: [.atomic, .completeFileProtection])
            let cache = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT", isDirectory: true)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let port = RemotePairingPort.discover()
            note("attaching to MacShack pid \(pid) (remote pairing port \(port.map { "\($0)" } ?? "49152: no Bonjour answer"))")
            // forceScript: our script is the whole protocol (pool prepare + detach), whatever TXM detection says.
            try StikJIT.enableJIT(targetPID: pid, pairingFile: pairing, ddiPaths: .default(in: cache),
                                  configuration: .init(rsdPort: port ?? 49152), script: .custom(script), forceScript: true,
                                  preparationProgress: { note("\($0)") }, progress: note)
            let item = NSExtensionItem()
            item.userInfo = ["log": lines.joined(separator: "\n")]
            context.completeRequest(returningItems: [item])
        } catch {
            note(error.localizedDescription)
            context.cancelRequest(withError: Self.error(lines.joined(separator: "\n")))
        }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "MacShackJIT", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// RemotePairing's port. iOS 27.0.1 does not always run it on StikJIT's default 49152 but announces it over Bonjour
// (51493 on an iPhone 17 Pro Max, 2026-10-28; StikDebug 70f761c does the same lookup). Ours is the service at one of
// this device's own addresses: other devices on the Wi-Fi announce theirs. nil: no answer in time.
final class RemotePairingPort: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var services: [NetService] = []
    private var port: UInt16?
    private let mine = RemotePairingPort.ownAddresses()

    static func discover(timeout: TimeInterval = 4) -> UInt16? {
        let finder = RemotePairingPort(), browser = NetServiceBrowser()
        browser.delegate = finder
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        let end = Date().addingTimeInterval(timeout)
        while finder.port == nil && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        browser.stop()
        finder.services.forEach { $0.stop() }
        return finder.port
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        if port == nil, (1...65535).contains(service.port),
           (service.addresses ?? []).contains(where: { mine.contains(Self.ip($0)) }) { port = UInt16(service.port) }
    }

    // A sockaddr's address bytes (IPv4 or IPv6), without port or scope; empty for anything else.
    private static func ip(_ sockaddr: Data) -> Data {
        sockaddr.withUnsafeBytes { raw -> Data in
            guard raw.count >= 2 else { return Data() }
            switch Int32(raw[1]) {   // sa_family
            case AF_INET where raw.count >= 8: return Data(raw[4..<8])
            case AF_INET6 where raw.count >= 24: return Data(raw[8..<24])
            default: return Data()
            }
        }
    }

    private static func ownAddresses() -> Set<Data> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out = Set<Data>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            if let a = entry.pointee.ifa_addr { out.insert(ip(Data(bytes: a, count: Int(a.pointee.sa_len)))) }
        }
        out.remove(Data())
        return out
    }
}
