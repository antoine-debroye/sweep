import Foundation
import AppKit

// MARK: - Name tokens

/// Normalizes folder and app names so "sync-tool" can be recognized as the data
/// folder of "SyncTool". Deliberately aggressive about punctuation and casing,
/// deliberately conservative about dropping words — every extra variant is a
/// chance to *suppress* a real leftover, but also a chance to match the wrong
/// app, and suppression is the safe direction.
public enum NameToken {
    /// Lowercase, strip diacritics, drop everything that isn't a letter or digit.
    public static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    /// Marketing suffixes that appear on a data folder but not on the app name
    /// (or the other way round): "Docker Desktop" ↔ "Docker".
    static let droppableSuffixes = [
        "desktop", "beta", "canary", "insiders", "nightly", "helper", "macos", "mac", "app",
    ]

    /// Generic reverse-DNS components and role words that identify nobody.
    ///
    /// Matching on these is how a name-based matcher goes wrong: a folder or
    /// launch item called "Helper", "Agent" or "Update" belongs to whichever
    /// app happens to be asked about it, so a match proves nothing.
    static let genericComponents: Set<String> = [
        // Domain-ish components.
        "com", "org", "net", "io", "co", "dev", "app", "id", "me", "us", "uk", "de", "fr",
        "ai", "xyz", "so", "sh", "tv", "gg", "cc", "inc", "ltd", "llc", "software", "apps",
        "group", "team", "labs", "studio", "technologies", "tech", "systems", "digital",
        // Role words.
        "helper", "agent", "daemon", "service", "services", "update", "updater", "sync",
        "backup", "cloud", "manager", "monitor", "server", "client", "worker", "runner",
        "launcher", "driver", "plugin", "extension", "widget", "utility", "utilities",
        "installer", "uninstaller", "framework", "shared", "common", "core", "main",
        "support", "resources", "data", "cache", "caches", "temp", "tmp", "logs",
        // Apple-app words that show up as launch-item and folder names.
        "music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts",
        "messages", "reminders", "clock", "weather", "stocks", "books", "news", "podcasts",
        "voice", "files", "store", "system",
    ]

    /// The normalized form plus the variants that should compare equal to it:
    /// trailing version numbers removed ("iStat Menus 7" → "istatmenus") and one
    /// trailing marketing suffix removed ("anythingllm-desktop" → "anythingllm").
    public static func variants(_ value: String) -> Set<String> {
        let base = normalize(value)
        guard !base.isEmpty else { return [] }
        var result: Set<String> = [base]
        for candidate in [base, stripTrailingDigits(base)] where !candidate.isEmpty {
            result.insert(candidate)
            if let stripped = stripOneSuffix(candidate) { result.insert(stripped) }
        }
        return result.filter { $0.count >= 3 }
    }

    static func stripTrailingDigits(_ value: String) -> String {
        var out = value
        while let last = out.last, last.isNumber { out.removeLast() }
        // Don't turn "3ds" style names into nothing, and don't strip a name that
        // is *only* digits.
        return out.count >= 3 ? out : value
    }

    static func stripOneSuffix(_ value: String) -> String? {
        for suffix in droppableSuffixes where value.hasSuffix(suffix) {
            let remainder = String(value.dropLast(suffix.count))
            if remainder.count >= 4 { return remainder }
        }
        return nil
    }

    /// Identity tokens for an installed app, split by what they identify.
    ///
    /// `app` = the app itself: display name, bundle *file* name, and the LAST
    /// bundle-id component. `vendor` = the publisher: the remaining bundle-id
    /// components. The split matters because it decides whether a folder is an
    /// app's own data (`Dropbox`, `Cursor` — never descend into it) or a
    /// vendor's shared folder while one of its apps is installed (`Adobe`,
    /// `Microsoft` — safe to look for dead per-app subfolders inside).
    static func identityTokens(
        name: String, bundleFileName: String, bundleID: String
    ) -> (app: Set<String>, vendor: Set<String>) {
        var app = variants(name).union(variants(bundleFileName))
        var vendor = Set<String>()
        let parts = bundleID.split(separator: ".").map(String.init)
        for (offset, part) in parts.enumerated() {
            let token = normalize(part)
            guard token.count >= 4,
                  !genericComponents.contains(token),
                  !droppableSuffixes.contains(token) else { continue }
            if offset == parts.count - 1 {
                app.formUnion(variants(token))
            } else {
                vendor.formUnion(variants(token))
            }
        }
        return (app, vendor)
    }
}

// MARK: - Installed app index

/// Everything the leftover scanner needs to know about what is installed,
/// captured once up front. Making this a value (with an injected LaunchServices
/// lookup) is what lets the scanner be a pure function of its inputs and be
/// tested against a fixture home.
public struct InstalledAppIndex: Sendable {
    /// Lowercased bundle ids of installed apps.
    public let bundleIDs: Set<String>
    /// Lowercased bundle ids of running apps.
    public let runningBundleIDs: Set<String>
    /// Lowercased running app names (Electron apps store data under their
    /// display name, so this is the only signal that catches them).
    public let runningNames: Set<String>
    /// Normalized identity tokens of every installed and running app
    /// (`appTokens` ∪ `vendorTokens`).
    public let tokens: Set<String>
    /// Tokens that name an app itself.
    public let appTokens: Set<String>
    /// Tokens that name a publisher rather than an app.
    public let vendorTokens: Set<String>
    /// Canonical executable paths of every running process we can see.
    ///
    /// An uninstalled app can leave a *running* background agent behind: on the
    /// machine this was built for, `figma_agent` runs out of
    /// `~/Library/Application Support/Figma/FigmaAgent.app` with the Figma app
    /// long gone. Deleting data underneath a live process is not a clean-up, so
    /// any folder hosting one is refused here and reported by LaunchItemAudit.
    public let runningExecutablePaths: Set<String>
    /// LaunchServices lookup. Injected so fixture tests never touch the real
    /// database, and memoized because a full scan asks about hundreds of ids.
    public let resolveBundleID: @Sendable (String) -> URL?

    public init(
        bundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        runningNames: Set<String> = [],
        tokens: Set<String> = [],
        vendorTokens: Set<String> = [],
        runningExecutablePaths: Set<String> = [],
        resolveBundleID: @escaping @Sendable (String) -> URL? = { InstalledAppIndex.launchServicesLookup($0) }
    ) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        self.runningNames = Set(runningNames.map { $0.lowercased() })
        // NOT `tokens.subtracting(vendorTokens)`. A token can legitimately be
        // both: "dropbox" is the last component of the installed app's id
        // (com.getdropbox.dropbox) *and* the vendor component of its running
        // updater (com.dropbox.DropboxMacUpdate). Subtracting dropped it from
        // appTokens and the updater's live data was offered as a leftover.
        self.appTokens = tokens
        self.vendorTokens = vendorTokens
        self.tokens = tokens.union(vendorTokens)
        self.runningExecutablePaths = runningExecutablePaths
        self.resolveBundleID = Memoizer(resolveBundleID).resolve
    }

    /// Builds an index from a nested inventory plus the running-app snapshot.
    public static func live(
        apps: [InstalledApp],
        runningBundleIDs: Set<String>,
        runningAppNames: Set<String>,
        runningExecutablePaths: Set<String> = [],
        resolveBundleID: @escaping @Sendable (String) -> URL? = { InstalledAppIndex.launchServicesLookup($0) }
    ) -> InstalledAppIndex {
        var appTokens = Set<String>()
        var vendorTokens = Set<String>()
        for app in apps where !app.isApple {
            let split = NameToken.identityTokens(
                name: app.name,
                bundleFileName: app.url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleID
            )
            appTokens.formUnion(split.app)
            vendorTokens.formUnion(split.vendor)
        }
        for name in runningAppNames {
            appTokens.formUnion(NameToken.variants(name))
        }
        for id in runningBundleIDs where !id.hasPrefix("com.apple.") {
            let split = NameToken.identityTokens(name: "", bundleFileName: "", bundleID: id)
            appTokens.formUnion(split.app)
            vendorTokens.formUnion(split.vendor)
        }
        return InstalledAppIndex(
            bundleIDs: Set(apps.map(\.bundleID)),
            runningBundleIDs: runningBundleIDs,
            runningNames: runningAppNames,
            tokens: appTokens,
            vendorTokens: vendorTokens,
            runningExecutablePaths: runningExecutablePaths,
            resolveBundleID: resolveBundleID
        )
    }

    /// True when any installed or running app answers to this folder name.
    public func matchesInstalledApp(name: String) -> Bool {
        let candidates = NameToken.variants(name)
        guard !candidates.isEmpty else { return false }
        if !candidates.isDisjoint(with: tokens) { return true }
        // Containment only between reasonably long tokens: "code" must not match
        // "visualstudiocode", or every four-letter folder would be suppressed.
        // Role words are excluded outright — "helper" is a substring of
        // "acmehelper", so allowing it would let a folder called "Helper" be
        // claimed by any app with a helper.
        for candidate in candidates
        where candidate.count >= 6 && !NameToken.genericComponents.contains(candidate) {
            for token in tokens where token.count >= 6 {
                if token.contains(candidate) || candidate.contains(token) { return true }
            }
        }
        return false
    }

    /// True when this folder name names a *publisher* of something installed
    /// but not any installed app itself — "Adobe" while Acrobat Distiller is
    /// installed. Exact membership only, no containment: containment would let
    /// "microsoft" match "microsoftword" and collapse the distinction this
    /// method exists to draw.
    public func isVendorOnlyMatch(name: String) -> Bool {
        let candidates = NameToken.variants(name)
        guard !candidates.isDisjoint(with: vendorTokens) else { return false }
        return candidates.isDisjoint(with: appTokens)
    }

    /// The path of a live process executing from inside `folder`, if any.
    public func runningExecutable(in folder: URL) -> String? {
        guard !runningExecutablePaths.isEmpty else { return nil }
        let prefix = SafetyPolicy.canonical(folder.path) + "/"
        return runningExecutablePaths.first { SafetyPolicy.canonical($0).hasPrefix(prefix) }
    }

    /// True when a live process is executing from inside `folder`.
    public func hostsRunningProcess(in folder: URL) -> Bool {
        runningExecutable(in: folder) != nil
    }

    public static func launchServicesLookup(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Thread-safe memo around the injected lookup. `NSLock` rather than an
    /// actor so the scanner stays synchronous and callable from `Task.detached`.
    private final class Memoizer: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: URL?] = [:]
        private let underlying: @Sendable (String) -> URL?

        init(_ underlying: @escaping @Sendable (String) -> URL?) { self.underlying = underlying }

        @Sendable func resolve(_ bundleID: String) -> URL? {
            lock.lock()
            if let cached = cache[bundleID] { lock.unlock(); return cached }
            lock.unlock()
            let value = underlying(bundleID)
            lock.lock()
            cache[bundleID] = value
            lock.unlock()
            return value
        }
    }
}

// MARK: - Nested inventory (suppression only)

public extension AppInventory {
    static func suppressionRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Setapp"),
            home.appending(path: "Applications"),
        ]
    }

    /// Apps discovered for orphan **suppression** only. Recurses up to
    /// `maxDepth` levels through ordinary folders and never descends into an
    /// `.app` bundle, so suite installs such as
    /// `/Applications/Adobe Acrobat DC/Acrobat Distiller.app` and
    /// `/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app`
    /// count as installed.
    ///
    /// Deliberately NOT used for the Uninstaller's app list:
    /// `UninstallGuard.mayRemoveAppBundle` refuses any bundle whose parent isn't
    /// exactly an Applications root, so listing nested apps there would offer an
    /// uninstall that then refuses itself.
    static func scanNested(
        roots: [URL]? = nil,
        maxDepth: Int = 4,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> [InstalledApp] {
        let fm = FileManager()
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        var queue: [(URL, Int)] = (roots ?? suppressionRoots(home: home)).map { ($0, 0) }

        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            if Task.isCancelled { break }
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if entry.pathExtension == "app" {
                    if let app = installedApp(at: entry), seen.insert(app.url.path).inserted {
                        apps.append(app)
                    }
                    continue  // never walk inside a bundle
                }
                if depth + 1 <= maxDepth { queue.append((entry, depth + 1)) }
            }
        }
        return apps
    }
}
