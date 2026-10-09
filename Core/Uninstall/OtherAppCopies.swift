import Foundation
import AppKit

/// Other installed copies of the app being uninstalled.
///
/// Leftovers are keyed by bundle id, and every copy with that id reads and
/// writes the same `~/Library/Application Support/<id>`, preferences and
/// containers. Uninstalling one copy while another remains must not take that
/// shared data with it.
///
/// LaunchServices already knows every registered copy, so this asks it rather
/// than crawling volumes — then filters out the registrations that are not
/// real, usable installs.
public struct OtherAppCopies: Sendable, Equatable {
    /// Copies that exist and could be launched.
    public var copies: [URL] = []
    /// Copies on a network volume. Touching a disconnected share can hang, so
    /// they are not examined — and since they can't be ruled out, they count.
    public var unchecked: [URL] = []

    public init(copies: [URL] = [], unchecked: [URL] = []) {
        self.copies = copies
        self.unchecked = unchecked
    }

    public var isEmpty: Bool { copies.isEmpty && unchecked.isEmpty }

    /// A sentence for the leftovers panel, or nil when there are none.
    public func note(appName: String) -> String? {
        if let copy = copies.first {
            return "Another copy of \(appName) is at \(copy.deletingLastPathComponent().path) and shares these "
                + "settings and data, so none are selected. Tick any you still want removed."
        }
        if let copy = unchecked.first {
            return "A copy of \(appName) is registered on a network volume (\(copy.deletingLastPathComponent().path)) "
                + "that Sweep can't check, so its shared settings and data are kept."
        }
        return nil
    }

    public typealias Lookup = @Sendable (_ bundleID: String) -> [URL]

    public static func find(
        bundleID: String,
        excluding appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        lookup: Lookup = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) },
        networkMounts: [String] = OtherAppCopies.networkMountPoints()
    ) -> OtherAppCopies {
        let fm = FileManager()
        let selected = canonical(appURL.path)
        var result = OtherAppCopies()
        var seen: Set<String> = [selected]

        let mounts = networkMounts.map { $0.lowercased() + "/" }
        for url in lookup(bundleID) {
            // Decided on the raw string first: resolving symlinks on a path
            // whose server has gone away is exactly the call that hangs.
            let raw = url.path.lowercased()
            if mounts.contains(where: { raw.hasPrefix($0) }) {
                if seen.insert(raw).inserted { result.unchecked.append(url) }
                continue
            }
            let path = canonical(url.path)
            guard seen.insert(path).inserted, isRealInstallLocation(path, home: home) else { continue }
            // LaunchServices keeps registrations for bundles that are gone.
            guard fm.fileExists(atPath: url.path) else { continue }
            // A mounted installer disk image is read-only; it is how the app
            // arrived, not a second install using the data.
            if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true { continue }
            result.copies.append(url)
        }
        return result
    }

    /// Registrations that are not an install someone runs: the Trash, an
    /// updater's staged copy inside ~/Library (Figma registers one inside its
    /// own support folder), Gatekeeper's App Translocation mirror of the very
    /// app being removed, and Time Machine's local snapshots.
    static func isRealInstallLocation(_ path: String, home: URL) -> Bool {
        let library = canonical(home.appending(path: "Library").path) + "/"
        let trash = canonical(home.appending(path: ".Trash").path) + "/"
        if path.hasPrefix(library) || path.hasPrefix(trash) { return false }
        if path.contains("/.trashes/") || path.contains("/apptranslocation/") { return false }
        if path.hasPrefix("/volumes/com.apple.timemachine.localsnapshots/")
            || path.contains("/.timemachine/") || path.contains("/backups.backupdb/") {
            return false
        }
        return true
    }

    /// One spelling per bundle: the Data-volume firmlink and symlinks resolve
    /// to the path the user sees, case-folded for APFS.
    static func canonical(_ path: String) -> String {
        var p = (path as NSString).resolvingSymlinksInPath
        if p.hasPrefix("/System/Volumes/Data/") { p.removeFirst("/System/Volumes/Data".count) }
        return SafetyPolicy.canonical(p)
    }

    /// Mount points of network filesystems, read from the kernel's mount table
    /// without touching the shares themselves (`MNT_NOWAIT`).
    public static func networkMountPoints() -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        let networkTypes: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]
        var points: [String] = []
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let type = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            guard networkTypes.contains(type) else { continue }
            let point = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            points.append(point)
        }
        return points
    }
}
