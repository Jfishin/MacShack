import Foundation
// Mac check: swiftc -parse-as-library host/ICNS.swift host/probe/test_icns.swift -o /tmp/t && /tmp/t [real.icns]
func entry(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let n = UInt32(body.count + 8)
    return Array(type.utf8) + [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + body
}
func icns(_ entries: [UInt8]) -> Data { Data(Array(entry("icns", entries))) }
@main struct TestICNS {
    static func main() {
        let png256: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
        let png512: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 9, 9]
        precondition(ICNS.bestImage(in: icns(entry("is32", [7, 7]) + entry("ic08", png256) + entry("ic09", png512))) == Data(png512),
                     "prefers the 512 px entry")
        precondition(ICNS.bestImage(in: icns(entry("is32", [7, 7]) + entry("ic08", png256))) == Data(png256), "falls back")
        precondition(ICNS.bestImage(in: icns(entry("ic09", [1, 2, 3]))) == nil, "ignores non-image bodies")
        precondition(ICNS.bestImage(in: Data([1, 2, 3])) == nil, "not an icns")
        // 16x16 legacy RGB: per channel a 130-pixel run (0xFF) + a 126-pixel run (0xFB), then a 256-byte mask.
        let plane: [UInt8] = [0xFF, 200, 0xFB, 100]
        let legacy = ICNS.bestImage(in: icns(entry("is32", plane + plane + plane) + entry("s8mk", [UInt8](repeating: 255, count: 256))))
        precondition(legacy?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "decodes legacy RLE into a PNG")
        precondition(ICNS.bestImage(in: icns(entry("is32", [0xFF, 1]))) == nil, "short RLE body")
        precondition(ICNS.bestImage(in: Data(Array("icns".utf8) + [0, 0, 0, 99] + Array("ic09".utf8) + [0, 0, 1, 0])) == nil,
                     "truncated entry")
        if CommandLine.arguments.count > 1 {
            let image = ICNS.bestImage(in: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(image?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "real icon has a PNG")
            print("real icon: \(image!.count) bytes")
        }
        print("icns ok")
    }
}
