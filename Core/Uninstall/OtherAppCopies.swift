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

    /// Beta, Nightly or Insiders builds of the same app (or the stable app,
    /// when removing one of those). They have their own bundle id, but often
    /// share folders named after the app, so nothing is pre-selected while
    /// one is installed. They don't count as copies for `isEmpty`: their
    /// background jobs and bundle-id data are their own.
    public var siblings: [URL] = []

    public init(copies: [URL] = [], unchecked: [URL] = [], siblings: [URL] = []) {
        self.copies = copies
        self.unchecked = unchecked
        self.siblings = siblings
    }

    public var isEmpty: Bool { copies.isEmpty && unchecked.isEmpty }

    /// Whether anything else installed may still use these leftovers.
    public var sharesData: Bool { !isEmpty || !siblings.isEmpty }

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
        if let sibling = siblings.first {
            return "\(sibling.deletingPathExtension().lastPathComponent) is also installed and may share some of "
                + "these settings and data, so none are selected. Tick any you still want removed."
        }
        return nil
    }

    // MARK: Sibling builds

    /// Trailing words that mark a pre-release or side-by-side build.
    static let variantWords: Set<String> = [
        "beta", "nightly", "canary", "insiders", "insider", "dev", "developer",
        "preview", "alpha",
    ]

    /// Other installed apps that are a different build of the same product:
    /// "Firefox" and "Firefox Nightly", `com.vendor.app` and
    /// `com.vendor.app.beta`. Matched by name with the variant word removed,
    /// or by bundle id with a variant component removed.
    public static func siblingBuilds(
        bundleID: String, appName: String, appURL: URL,
        installed: [(url: URL, name: String, bundleID: String)]
    ) -> [URL] {
        let ownName = baseName(appName)
        let ownID = baseBundleID(bundleID)
        return installed.compactMap { other in
            guard other.url.standardizedFileURL != appURL.standardizedFileURL,
                  other.bundleID.lowercased() != bundleID.lowercased() else { return nil }
            let sameName = ownName.count >= 3 && baseName(other.name) == ownName
            let sameID = ownID.split(separator: ".").count >= 3 && baseBundleID(other.bundleID) == ownID
            return sameName || sameID ? other.url : nil
        }
    }

    /// "Firefox Nightly" → "firefox", "Visual Studio Code - Insiders" → "visual studio code".
    static func baseName(_ name: String) -> String {
        var words = name.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .map(String.init)
        if words.count > 1, let last = words.last, variantWords.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// `com.vendor.app.beta` → `com.vendor.app`, `com.microsoft.vscodeinsiders` → `com.microsoft.vscode`.
    static func baseBundleID(_ id: String) -> String {
        var parts = id.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 3, var last = parts.last else { return id.lowercased() }
        if variantWords.contains(last) {
            parts.removeLast()
        } else if let word = variantWords.first(where: { last.hasSuffix($0) && last.count > $0.count + 2 }) {
            last.removeLast(word.count)
            parts[parts.count - 1] = last
        }
        return parts.joined(separator: ".")
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
