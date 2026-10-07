import Foundation
import StikJIT

// MacShack's built-in JIT enabler: a hidden share extension that MacShack starts for its own PID
// (host/ShackJITHelper.m). A debugger client cannot live in MacShack itself: attaching suspends every thread of the
// target, the client's included. StikJIT connects through LocalDevVPN (10.7.0.1:49152) with the imported pairing
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
            note("attaching to MacShack pid \(pid)")
            // forceScript: our script is the whole protocol (pool prepare + detach), whatever TXM detection says.
            try StikJIT.enableJIT(targetPID: pid, pairingFile: pairing, ddiPaths: .default(in: cache),
                                  script: .custom(script), forceScript: true,
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
