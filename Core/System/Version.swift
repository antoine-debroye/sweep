import Foundation

/// A minimal semantic version (`major.minor.patch`) used to compare the running
/// app against the latest GitHub release. Kept in `Core` — pure Foundation, no
/// UI/network — so it can be unit-tested by `SweepTests`.
///
/// Parsing is deliberately lenient: a leading `v`/`V` is stripped, a trailing
/// pre-release/build suffix (`-beta.1`, `+sha`) is ignored for ordering, and
/// missing minor/patch components default to `0` (`"2"` == `"2.0.0"`). Anything
/// that doesn't start with a number fails to parse (`nil`).
public struct SemanticVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"1.2.3"`, `"v1.2.3"`, `"2.0"`, `"3"`, `"1.4.0-beta.2"`. Returns
    /// `nil` for empty or non-numeric-leading input.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        // Drop any pre-release / build metadata so ordering is on the core triple.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        func component(_ index: Int) -> Int? {
            guard index < parts.count else { return 0 } // missing → 0
            return Int(parts[index])
        }
        guard let major = component(0), let minor = component(1), let patch = component(2) else {
            return nil
        }
        // Reject anything with extra numeric components we didn't expect only if
        // they aren't parseable; otherwise 1.2.3.4 collapses harmlessly to 1.2.3.
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
