import Foundation

/// XPC protocol between the Sweep app and the privileged helper daemon.
/// Compiled into both the app (via SweepCore) and the helper tool, so the
/// runtime name is pinned with @objc to survive module differences.
@objc(SweepHelperProtocol)
public protocol SweepHelperProtocol {
    /// Returns the helper build version so the app can detect stale installs.
    func version(reply: @escaping @Sendable (String) -> Void)

    /// Runs `/usr/sbin/purge` to flush inactive memory / disk cache.
    func purgeMemory(reply: @escaping @Sendable (Int32, String) -> Void)

    /// Removes the given absolute paths. The helper re-validates every path
    /// against `PrivilegedPathPolicy` — anything outside the allow-list is
    /// rejected, the call never becomes an arbitrary rm-as-root.
    func removePaths(_ paths: [String], reply: @escaping @Sendable (Int32, String) -> Void)

    /// Runs one of the allow-listed maintenance tasks (see `MaintenanceTask`).
    func runMaintenance(_ taskID: String, reply: @escaping @Sendable (Int32, String) -> Void)
}

public enum SweepHelperConstants {
    public static let machServiceName = "com.debroye.sweep.helper"
    public static let daemonPlistName = "com.debroye.sweep.helper.plist"
    public static let version = "1.0.0"
    /// Developer ID team the helper accepts clients from (pinned in its
    /// code requirement in Helper/main.swift).
    public static let teamIdentifier = "FC27NYGHX4"
}

/// Maintenance tasks the helper is willing to execute. Each case maps to a
/// fixed command line — callers pick a task, never a command.
public enum MaintenanceTask: String, CaseIterable, Sendable {
    case flushDNS
    case rebuildSpotlight
    case thinLocalSnapshots

    public var commandLine: (path: String, args: [String]) {
        switch self {
        case .flushDNS:
            // dscacheutil first; mDNSResponder HUP is chained by the helper.
            return ("/usr/bin/dscacheutil", ["-flushcache"])
        case .rebuildSpotlight:
            return ("/usr/bin/mdutil", ["-E", "/"])
        case .thinLocalSnapshots:
            return ("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "9999999999999", "4"])
        }
    }
}

/// Shared validation for privileged deletions, used by the helper (authoritative)
/// and by the app (to fail fast before prompting). Only regenerable
/// system-domain junk locations are allowed; the roots themselves are not.
public enum PrivilegedPathPolicy {
    public static let allowedRoots: [String] = [
        "/Library/Caches/",
        "/Library/Logs/",
        "/private/var/log/",
        "/private/var/folders/",
        "/Library/Updates/",
    ]

    public static let deniedSubstrings: [String] = [
        "..",
        "/private/var/log/asl.conf",
    ]

    public static func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var standardized = (path as NSString).standardizingPath
        // standardizingPath strips the /private prefix; restore it so the
        // comparison happens in one canonical form.
        for stripped in ["/var/", "/tmp/", "/etc/"] where standardized.hasPrefix(stripped) {
            standardized = "/private" + standardized
        }
        guard standardized.count > 1 else { return false }
        // Denied substrings are checked against BOTH the raw and the normalized
        // form. Checking only the raw path would let a carve-out like asl.conf
        // be bypassed by spelling it "/var/log/asl.conf" (which only matches an
        // allowed root after /private is re-added). '..' is still caught on the
        // raw path, before standardizing resolves it away.
        for bad in deniedSubstrings where path.contains(bad) || standardized.contains(bad) { return false }
        for root in allowedRoots {
            // Must be strictly inside an allowed root, never the root itself.
            if standardized.hasPrefix(root), standardized.count > root.count {
                return true
            }
        }
        return false
    }

    /// Authoritative check for the privileged deleter. A path must be
    /// allow-listed BOTH lexically and after resolving symbolic links, so an
    /// intermediate symlink (e.g. /Library/Caches/link -> /System) can't
    /// redirect a root-level deletion outside the allow-list.
    public static func isAllowedResolvingSymlinks(_ path: String) -> Bool {
        guard isAllowed(path) else { return false }
        let resolved = (path as NSString).resolvingSymlinksInPath
        return resolved == path || isAllowed(resolved)
    }
}
