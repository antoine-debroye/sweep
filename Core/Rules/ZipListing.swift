import Foundation

/// Reads entry names from a ZIP's central directory — the index at the end of
/// the file — without extracting anything or running a subprocess. Enough to
/// tell an app download (`Foo.app/…`, `Setup.pkg`) from a folder of photos.
enum ZipListing {
    /// Names of the first `limit` entries, or nil if this isn't a readable ZIP.
    static func entryNames(of url: URL, limit: Int = 50) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return nil }

        // End-of-central-directory record: fixed 22 bytes plus a comment of up
        // to 65,535 bytes, so it lives somewhere in the last 65,557 bytes.
        let tailLength = min(fileSize, 65_557)
        guard (try? handle.seek(toOffset: fileSize - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: bytes), eocd + 22 <= bytes.count else { return nil }

        var directoryOffset = UInt64(le32(bytes, eocd + 16))
        var directorySize = UInt64(le32(bytes, eocd + 12))
        if directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
            // ZIP64: a locator 20 bytes before the classic record points at the
            // 64-bit record holding the real offsets.
            let locator = eocd - 20
            guard locator >= 0, Array(bytes[locator..<locator + 4]) == [0x50, 0x4B, 0x06, 0x07] else { return nil }
            let recordOffset = le64(bytes, locator + 8)
            guard recordOffset + 56 <= fileSize, (try? handle.seek(toOffset: recordOffset)) != nil,
                  let record = try? handle.read(upToCount: 56), record.count == 56 else { return nil }
            let r = [UInt8](record)
            guard Array(r[0..<4]) == [0x50, 0x4B, 0x06, 0x06] else { return nil }
            directorySize = le64(r, 40)
            directoryOffset = le64(r, 48)
        }
        guard directoryOffset < fileSize else { return nil }

        // The first `limit` names fit comfortably in 1 MB of directory.
        let readLength = Int(min(directorySize, 1_048_576, fileSize - directoryOffset))
        guard (try? handle.seek(toOffset: directoryOffset)) != nil,
              let directory = try? handle.read(upToCount: readLength) else { return nil }
        let d = [UInt8](directory)

        var names: [String] = []
        var cursor = 0
        while names.count < limit, cursor + 46 <= d.count,
              Array(d[cursor..<cursor + 4]) == [0x50, 0x4B, 0x01, 0x02] {
            let nameLength = Int(le16(d, cursor + 28))
            let extraLength = Int(le16(d, cursor + 30))
            let commentLength = Int(le16(d, cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= d.count else { break }
            let raw = Data(d[nameStart..<nameStart + nameLength])
            names.append(String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return names.isEmpty ? nil : names
    }

    /// True when the archive's leading entries contain an app bundle or an
    /// installer image/package.
    static func looksLikeInstaller(_ url: URL) -> Bool {
        guard let names = entryNames(of: url) else { return false }
        return names.contains { name in
            let lower = name.lowercased()
            if lower.hasPrefix("__macosx/") { return false }
            return lower.contains(".app/")
                || [".pkg", ".mpkg", ".dmg", ".xip"].contains { lower.hasSuffix($0) || lower.hasSuffix($0 + "/") }
        }
    }

    private static func lastIndex(of signature: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= signature.count else { return nil }
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == signature[0], bytes[i + 1] == signature[1],
               bytes[i + 2] == signature[2], bytes[i + 3] == signature[3] { return i }
            i -= 1
        }
        return nil
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
    }
}
