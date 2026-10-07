import Foundation

// Steam setup (SteamClientManifest) reads Valve's text VDF with it; plain Foundation, so
// host/probe/test_steam_setup.swift compiles it alone.

// MARK: - Simple VDF Binary Parser

/// Parses Valve Data Format (binary) used in PICS responses
enum VDFParser {
    // VDF binary types
    private static let typeNone: UInt8 = 0x00
    private static let typeString: UInt8 = 0x01
    private static let typeInt32: UInt8 = 0x02
    private static let typeEnd: UInt8 = 0x08

    /// Parse a text-format VDF / KeyValues blob into a nested dictionary.
    /// Steam PICS sends *app* product info in this text format (`"key" "value"`
    /// pairs and `"key" { ... }` sections) — package info uses the binary
    /// format. Leaf values are always `String`. Standard VDF does not process
    /// escape sequences, so a quoted string runs verbatim to the next `"`.
    static func parseTextVDF(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func skipWhitespaceAndComments() {
            while i < n {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                    while i < n && scalars[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func nextToken() -> String? {
            skipWhitespaceAndComments()
            guard i < n else { return nil }
            let c = scalars[i]
            if c == "{" || c == "}" {
                i += 1
                return String(c)
            }
            var s = ""
            if c == "\"" {
                i += 1
                while i < n && scalars[i] != "\"" {
                    s.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1 // closing quote
                return s
            }
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                    || ch == "{" || ch == "}" || ch == "\"" { break }
                s.unicodeScalars.append(ch)
                i += 1
            }
            return s
        }

        func parseSection() -> [String: Any] {
            var dict: [String: Any] = [:]
            while let key = nextToken() {
                if key == "}" { break }
                if key == "{" { continue }
                guard let value = nextToken() else { break }
                if value == "{" {
                    dict[key] = parseSection()
                } else if value == "}" {
                    break
                } else {
                    dict[key] = value
                }
            }
            return dict
        }

        return parseSection()
    }

    /// Extract app IDs from a binary VDF package info buffer
    static func parsePackageAppIDs(from data: Data) -> [UInt32] {
        var appIDs: [UInt32] = []
        var offset = 0

        // Look for "appids" section and extract UInt32 values
        // This is a simplified parser that searches for known patterns
        let searchKey = "appids"
        if let range = findKey(searchKey, in: data) {
            offset = range
            // After "appids" key, we expect sub-keys with numeric names and uint32 values
            while offset < data.count {
                guard offset < data.count else { break }
                let type = data[offset]
                offset += 1

                if type == typeEnd { break }

                // Read key name (null-terminated string)
                guard let (_, newOffset) = readNullTerminatedString(from: data, at: offset) else { break }
                offset = newOffset

                if type == typeInt32 {
                    guard offset + 4 <= data.count else { break }
                    let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                    appIDs.append(UInt32(littleEndian: value))
                    offset += 4
                } else if type == typeString {
                    guard let (_, newOff) = readNullTerminatedString(from: data, at: offset) else { break }
                    offset = newOff
                } else if type == typeNone {
                    // Sub-section - skip or recurse
                    continue
                }
            }
        }

        return appIDs
    }

    private static func findKey(_ key: String, in data: Data) -> Int? {
        let keyBytes = Array(key.utf8) + [0] // null-terminated
        let keyData = Data(keyBytes)
        guard data.count >= keyData.count else { return nil }

        for i in 0..<(data.count - keyData.count) {
            if data[i..<i + keyData.count] == keyData {
                return i + keyData.count
            }
        }
        return nil
    }

    private static func readNullTerminatedString(from data: Data, at offset: Int) -> (String, Int)? {
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        guard end < data.count else { return nil }
        let str = String(data: data[offset..<end], encoding: .utf8) ?? ""
        return (str, end + 1)
    }
}
