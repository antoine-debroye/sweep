import Foundation

/// The hard safety boundary of Sweep. Both the scanner and the cleaner consult
/// this policy independently (defense in depth): nothing inside a protected
/// subtree is ever offered, selected, or deleted by rule-based cleaning.
///
/// The uninstaller does not go through this check for the .app bundle itself —
/// it has its own, narrower validation (`UninstallGuard`).
public struct SafetyPolicy: Sendable {
    public let home: URL

    /// Subtrees that are completely off-limits: the node and everything below.
    public let protectedSubtrees: [String]
    /// Nodes that may not be deleted themselves, but whose children may be
    /// (e.g. ~/Library/Caches: we trim its contents, never the folder).
    public let protectedExactNodes: [String]
    /// Live state that sits *inside* a cache-like folder. The node and its
    /// subtree are protected like `protectedSubtrees`, and so is every folder
    /// above it — deleting `Caches/org.R-project.R` removes the renv library
    /// inside it just as surely as deleting the library itself.
    public let liveDataNodes: [String]

    /// Canonical `~/Library`.
    let libraryRoot: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        let h = home.path
        self.libraryRoot = SafetyPolicy.canonical("\(h)/Library")

        var subtrees = [
            "\(h)/Documents",
            "\(h)/Desktop",
            "\(h)/Pictures",
            "\(h)/Music",
            "\(h)/Movies",
            "\(h)/Public",
            "\(h)/Applications",
            "\(h)/Library/Mobile Documents",   // iCloud Drive
            "\(h)/Library/CloudStorage",       // Dropbox / Google Drive / OneDrive mounts
            "\(h)/Library/Keychains",
            "\(h)/Library/Mail",
            "\(h)/Library/Messages",
            "\(h)/Library/Photos",
            "\(h)/Library/Wallet",
            "\(h)/Library/Accounts",
            "\(h)/Library/Passes",
            "\(h)/Library/Autosave Information",
            "\(h)/.ssh",
            "\(h)/.gnupg",
            "\(h)/.aws",
            "\(h)/.config",
            "\(h)/.kube",
            // Claude Code's own history: session transcripts (`--resume`),
            // per-file edit history (rewind) and prompt history. Not a cache,
            // and gone for good once deleted. Agent worktrees elsewhere under
            // ~/.claude stay visible to WorktreeScanner.
            "\(h)/.claude/projects",
            "\(h)/.claude/file-history",
            "\(h)/.claude/history.jsonl",
            "\(h)/.claude/todos",
        ]
        subtrees += [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/private/etc",
            "/private/var/db",
            "/Users/Shared",
            "/Library/Application Support",
            "/Library/LaunchDaemons",
            "/Library/Extensions",
            "/Library/Frameworks",
            "/Library/Keychains",
        ]
        // Cloud sync clients that use the File Provider framework keep the
        // REAL synced files inside a group container (OneDrive:
        // ~/Library/Group Containers/<team>.OneDriveSyncClientSuite), not under
        // ~/Library/CloudStorage — that folder is only the visible mount.
        // Trashing the backing store would delete the files remotely too, so the
        // whole container is off-limits, detected by name and by the presence
        // of a "File Provider Storage" folder.
        subtrees += SafetyPolicy.fileProviderContainers(home: home)
        self.protectedSubtrees = subtrees.map(SafetyPolicy.canonical)

        self.liveDataNodes = [
            // Google's pseudonymous ID and Clearcut log queue. No dot in the
            // name, so no running-app check ever claims them; with them gone a
            // running Gemini rewrites its state at ~50 MB/s until it quits.
            "\(h)/Library/Caches/GIPPseudonymousID",
            "\(h)/Library/Caches/CCTClearcutLogger",
            // renv installs R packages here and symlinks them into every
            // project library; deleting the cache leaves those links dangling.
            "\(h)/Library/Caches/org.R-project.R/R/renv",
            // Poetry's project virtualenvs (live interpreters), not a cache.
            "\(h)/Library/Caches/pypoetry/virtualenvs",
            // Deno keeps origin storage (localStorage) for --location scripts
            // inside its cache root; the module caches beside it are offered.
            "\(h)/Library/Caches/deno/location_data",
            // Kitty's graphics-protocol cache: a running terminal session
            // streams images through it and breaks if it vanishes.
            "\(h)/Library/Caches/kitty",
        ].map(SafetyPolicy.canonical)

        self.protectedExactNodes = [
            h,
            "\(h)/Library",
            "\(h)/Library/Application Support",
            "\(h)/Library/Caches",
            "\(h)/Library/Logs",
            // The crash reporter cannot recreate this folder from its sandbox;
            // once it is gone every later crash report is silently dropped.
            // Its reports may go, the folder may not.
            "\(h)/Library/Logs/DiagnosticReports",
            "\(h)/Library/DiagnosticReports",
            "\(h)/Library/Preferences",
            "\(h)/Library/Containers",
            "\(h)/Library/Group Containers",
            "\(h)/Library/Developer",
            "\(h)/Downloads",
            "/",
            "/Library",
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "/private/var/folders",
            "/Applications",
        ].map(SafetyPolicy.canonical)
    }

    /// true when the URL must never be deleted. APFS is case-insensitive by
    /// default, so comparison is case-folded.
    public func isProtected(_ url: URL) -> Bool {
        let path = SafetyPolicy.canonical(url.path)
        for node in protectedExactNodes where path == node { return true }
        // Every folder directly inside ~/Library or /Library (Fonts,
        // LaunchAgents, Application Scripts…): its contents may be cleaned,
        // the folder itself never goes. Apps and macOS expect them to exist.
        let parent = (path as NSString).deletingLastPathComponent
        if parent == libraryRoot || parent == "/library" { return true }
        for subtree in protectedSubtrees {
            if path == subtree || path.hasPrefix(subtree + "/") { return true }
        }
        for live in liveDataNodes {
            if path == live || path.hasPrefix(live + "/") || live.hasPrefix(path + "/") { return true }
        }
        return false
    }

    /// `isProtected`, also applied to where the path really leads. A cleanable
    /// folder can be a symlink into a protected one (`Logs/DiagnosticReports`
    /// → `~/Documents/reports`); the written path looks harmless while the
    /// files it reaches are not. Only the *parent* is resolved: a symlink
    /// item itself is safe to remove — that moves the link, not its target.
    /// Kept out of `isProtected` because resolving costs a stat per component
    /// and that one runs inside whole-tree walks.
    public func isProtectedOrRedirected(_ url: URL) -> Bool {
        if isProtected(url) { return true }
        let parent = url.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard SafetyPolicy.canonical(resolvedParent.path) != SafetyPolicy.canonical(parent.path) else { return false }
        return isProtected(resolvedParent.appending(path: url.lastPathComponent))
    }

    /// true when the URL sits under a user-provided whitelist prefix.
    public static func isWhitelisted(_ url: URL, whitelist: [String]) -> Bool {
        guard !whitelist.isEmpty else { return false }
        let path = canonical(url.path)
        for entry in whitelist {
            let w = canonical(entry)
            guard !w.isEmpty else { continue }
            if path == w || path.hasPrefix(w + "/") { return true }
        }
        return false
    }

    /// Group containers that hold a cloud sync client's backing store.
    static func fileProviderContainers(home: URL) -> [String] {
        let fm = FileManager()
        let root = home.appending(path: "Library/Group Containers")
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { entry in
            let name = entry.lastPathComponent.lowercased()
            if name.contains("onedrive") { return entry.path }
            if fm.fileExists(atPath: entry.appending(path: "File Provider Storage").path) { return entry.path }
            return nil
        }
    }

    static func canonical(_ path: String) -> String {
        var p = (path as NSString).standardizingPath.lowercased()
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// Validation for the explicit uninstall flow: the only things it may remove
/// are an .app bundle inside an Applications folder, or leftover entries the
/// finder located inside the known per-app data roots.
/// Why an uninstall was refused, or that it may proceed.
public enum UninstallVerdict: Sendable, Equatable {
    case allowed
    case refused(String)

    public var isAllowed: Bool { self == .allowed }
    public var reason: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

public enum UninstallGuard {
    /// Identity-level check, on top of the path-level `mayRemoveAppBundle`.
    /// Deleting a security agent's bundle strands its system extension and
    /// daemons and can break a managed Mac's compliance, so Sweep refuses and
    /// points at the vendor's tooling instead.
    public static func verdict(for app: InstalledApp) -> UninstallVerdict {
        if app.isApple || BundleProtection.isSystemCritical(app.bundleID) {
            return .refused("\(app.name) is part of the system or a platform dependency. "
                + "Sweep won't remove it.")
        }
        if BundleProtection.isSecurityAgent(app.bundleID) {
            return .refused("\(app.name) is a security or device-management agent. Remove it through "
                + "the vendor's uninstaller or your MDM — deleting it here would leave its system "
                + "extension and daemons running.")
        }
        guard mayRemoveAppBundle(app.url) else {
            return .refused("Sweep only removes apps that live directly in an Applications folder.")
        }
        return .allowed
    }

    public static func mayRemoveAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let parent = SafetyPolicy.canonical(url.deletingLastPathComponent().path)
        let home = SafetyPolicy.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
        return parent == "/applications" || parent == home + "/applications"
    }
}
