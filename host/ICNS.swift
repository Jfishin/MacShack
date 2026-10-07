import Foundation
import ImageIO
import UniformTypeIdentifiers

// Apple icon files: "icns", a big-endian total length, then entries of type (4 bytes) + big-endian length (including
// the 8-byte header) + body. ic07...ic14 hold whole PNG or JPEG 2000 images. Older files (Factorio) have only legacy
// bitmaps: RLE-packed RGB planes (it32/ih32/il32/is32) plus an 8-bit alpha mask, turned into a PNG here.
enum ICNS {
    // 512 px first: sharp in a ~110 pt tile at 3x without decoding a 1024 px image per tile.
    static let preference = ["ic09", "ic14", "ic10", "ic08", "ic13", "ic07", "ic12", "ic11"]
    static let legacy: [(rgb: String, mask: String, side: Int)] =
        [("it32", "t8mk", 128), ("ih32", "h8mk", 48), ("il32", "l8mk", 32), ("is32", "s8mk", 16)]

    static func bestImage(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("icns".utf8) else { return nil }
        var found: [String: Data] = [:]
        var at = 8
        while at + 8 <= bytes.count {
            let type = String(decoding: bytes[at..<at + 4], as: UTF8.self)
            let length = Int(bytes[at + 4]) << 24 | Int(bytes[at + 5]) << 16 | Int(bytes[at + 6]) << 8 | Int(bytes[at + 7])
            guard length >= 8, at + length <= bytes.count else { break }
            found[type] = Data(bytes[at + 8..<at + length])
            at += length
        }
        if let image = preference.lazy.compactMap({ found[$0] }).first(where: isImage) { return image }
        return legacy.lazy.compactMap { l in found[l.rgb].flatMap { png(rgb: $0, mask: found[l.mask], side: l.side) } }.first
    }

    static func isImage(_ d: Data) -> Bool {
        d.starts(with: [0x89, 0x50, 0x4E, 0x47]) || d.starts(with: [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50])
    }

    // Each of R, G, B is packed separately: n < 0x80 copies n + 1 literal bytes, otherwise the next byte repeats
    // n - 0x80 + 3 times. it32 bodies start with 4 zero bytes. An uncompressed body is 4 bytes per pixel (ARGB).
    static func png(rgb: Data, mask: Data?, side: Int) -> Data? {
        let count = side * side
        var src = [UInt8](rgb)
        var rgba = [UInt8](repeating: 255, count: count * 4)
        if src.count == count * 4 {
            for i in 0..<count { for c in 0..<3 { rgba[i * 4 + c] = src[i * 4 + 1 + c] }; rgba[i * 4 + 3] = src[i * 4] }
        } else {
            if side == 128, src.starts(with: [0, 0, 0, 0]) { src.removeFirst(4) }
            var at = 0
            for c in 0..<3 {
                var px = 0
                while px < count {
                    guard at < src.count else { return nil }
                    let n = Int(src[at]); at += 1
                    if n < 0x80 {
                        guard at + n + 1 <= src.count, px + n + 1 <= count else { return nil }
                        for k in 0...n { rgba[(px + k) * 4 + c] = src[at + k] }
                        at += n + 1; px += n + 1
                    } else {
                        let run = n - 0x80 + 3
                        guard at < src.count, px + run <= count else { return nil }
                        for k in 0..<run { rgba[(px + k) * 4 + c] = src[at] }
                        at += 1; px += run
                    }
                }
            }
        }
        if let mask, mask.count == count { for (i, a) in mask.enumerated() { rgba[i * 4 + 3] = a } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
