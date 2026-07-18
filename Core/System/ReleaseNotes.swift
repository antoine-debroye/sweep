import Foundation

/// Parsing of the machine-readable metadata `Scripts/release.sh` writes into a
/// GitHub release body. Pure Foundation, so it lives in `Core` and is unit-tested.
public enum ReleaseNotes {
    /// Extracts the 64-char hex digest from a `zip-sha256: <hex>` line, or `nil`.
    ///
    /// Index-safe: the search range and the slice operate on the **same** string.
    /// (A previous version searched a lowercased copy and then sliced the original
    /// with that index — String indices aren't portable across instances, which
    /// trapped at launch once a release actually contained the line.)
    public static func parseZipSHA256(from notes: String) -> String? {
        for rawLine in notes.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let range = line.range(of: "zip-sha256:", options: [.caseInsensitive]) else { continue }
            let hex = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { return hex }
        }
        return nil
    }
}
