import Foundation
import AppKit

// MARK: - Installed apps

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String?
    public var size: Int64?
    public var lastUsed: Date?

    public var id: String { url.path }
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
}

public enum AppInventory {
    public static func scan() async -> [InstalledApp] {
        let fm = FileManager()
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
        var apps: [InstalledApp] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            // A dot-prefixed bundle is a hidden backup (an updater's copy),
            // not an installation the user sees in Finder.
            for entry in entries where entry.pathExtension == "app" && !entry.lastPathComponent.hasPrefix(".") {
                if let app = installedApp(at: entry) { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Builds an `InstalledApp` for a single `.app` bundle, or nil if it isn't a
    /// readable app. Shared by the inventory scan and the Finder "Uninstall with
    /// Sweep" service (which hands us an arbitrary bundle URL).
    public static func installedApp(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (FileManager().displayName(atPath: url.path) as NSString).deletingPathExtension
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return InstalledApp(url: url, name: name, bundleID: bundleID, version: version, size: nil, lastUsed: lastUsedDate(for: url))
    }

    public static func lastUsedDate(for url: URL) -> Date? {
        let item = MDItemCreateWithURL(nil, url as CFURL)
        guard let item else {
            return try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
        }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Leftover finder

/// How aggressively the leftover finder searches. Higher tiers add more
/// locations and looser matching; the extra deep-only hits are flagged
/// `.review` so they're surfaced but never pre-selected.
public enum MatchDepth: String, Sendable, CaseIterable, Identifiable {
    /// Exact bundle-id matches only. Safest; may miss some files.
    case strict
    /// Adds app-name matches and shared-container / launch-agent prefix matches.
    /// The default — reproduces Sweep's long-standing behavior, plus a few more
    /// exact locations.
    case enhanced
    /// Also finds team-identifier app groups and heuristic name matches across
    /// plug-in / extension roots. These extra hits are marked "Review".
    case deep

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .strict: "Strict"
        case .enhanced: "Enhanced"
        case .deep: "Deep"
        }
    }

    public var blurb: String {
        switch self {
        case .strict: "Exact bundle-ID matches only."
        case .enhanced: "Adds app-name and shared-container matches."
        case .deep: "Also finds team-ID and heuristic matches to review."
        }
    }
}

/// Locates everything an app scattered across the user's Library (and a few
/// system locations) for a complete uninstall. Confidence is encoded in each
/// item's `tier`: exact bundle-id / app-name hits are `.explicitOnly` (safe to
/// pre-select); team-ID and heuristic hits are `.review` (surfaced, not
/// pre-selected).
public enum LeftoverFinder {
    /// The app's name, plus the name without a trailing release number
    /// ("Alfred 4" → "Alfred", "Foo-2.1" → "Foo"). The number has to be its
    /// own word: "Sweep2" stays as it is.
    static func dataFolderNames(for appName: String) -> [String] {
        var names = [appName]
        let pattern = #"^(.*\S)[ \-]+v?\d+(\.\d+)*$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let found = regex.firstMatch(in: appName, range: NSRange(appName.startIndex..., in: appName)),
           let base = Range(found.range(at: 1), in: appName) {
            let stripped = String(appName[base])
            if stripped.count >= 3, stripped != appName { names.append(stripped) }
        }
        return names
    }

    /// Library folders that hold what the user made or set up in an app:
    /// documents, settings, accounts, sign-ins, local databases. Uninstalling
    /// is often a step before reinstalling, so these are listed but not
    /// pre-selected. Caches, logs, saved window state, crash reports and
    /// launch agents are disposable and stay pre-selected.
    static let personalDataRoots = [
        "Application Support", "Preferences", "Containers", "Group Containers",
        "WebKit", "HTTPStorages", "Cookies", "SyncedPreferences", "Application Scripts",
    ]

    public static func isPersonalData(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = SafetyPolicy.canonical(url.path)
        let library = SafetyPolicy.canonical(home.appending(path: "Library").path) + "/"
        guard path.hasPrefix(library) else { return false }
        let relative = String(path.dropFirst(library.count))
        if relative.hasPrefix("application support/crashreporter/") { return false }
        return personalDataRoots.contains { relative.hasPrefix($0.lowercased() + "/") }
    }

    public static func find(
        bundleID: String,
        appName: String,
        teamID: String? = nil,
        depth: MatchDepth = .enhanced,
        appURL: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ScanItem] {
        let fm = FileManager()
        let lib = home.appending(path: "Library")
        var found: [ScanItem] = []
        var seen = Set<String>()

        // (url, label, confidence tier). All depths include the exact bundle-id
        // locations below.
        var candidates: [(URL, String, SafetyTier)] = [
            (lib.appending(path: "Application Support/\(bundleID)"), "Application support", .explicitOnly),
            (lib.appending(path: "Caches/\(bundleID)"), "Caches", .explicitOnly),
            (lib.appending(path: "Preferences/\(bundleID).plist"), "Preferences", .explicitOnly),
            (lib.appending(path: "Preferences/\(bundleID).plist.lockfile"), "Preferences lock", .explicitOnly),
            (lib.appending(path: "Logs/\(bundleID)"), "Logs", .explicitOnly),
            (lib.appending(path: "Containers/\(bundleID)"), "Container", .explicitOnly),
            (lib.appending(path: "Saved Application State/\(bundleID).savedState"), "Saved state", .explicitOnly),
            (lib.appending(path: "WebKit/\(bundleID)"), "WebKit data", .explicitOnly),
            (lib.appending(path: "HTTPStorages/\(bundleID)"), "HTTP storage", .explicitOnly),
            (lib.appending(path: "Cookies/\(bundleID).binarycookies"), "Cookies", .explicitOnly),
            (lib.appending(path: "Application Scripts/\(bundleID)"), "App scripts", .explicitOnly),
            (lib.appending(path: "SyncedPreferences/\(bundleID).plist"), "Synced preferences", .explicitOnly),
        ]
        // Per-host preferences: <bundleID>.<UUID>.plist under Preferences/ByHost.
        candidates += matching(in: lib.appending(path: "Preferences/ByHost"), containing: bundleID, label: "Per-host preferences", fm: fm)
            .filter { $0.0.lastPathComponent.lowercased().hasPrefix(bundleID.lowercased() + ".") }
            .map { ($0.0, $0.1, SafetyTier.explicitOnly) }

        if depth == .enhanced || depth == .deep {
            // "Alfred 4" keeps its data in "Alfred": a release number in the
            // app's name is rarely in its data folder's name.
            for name in LeftoverFinder.dataFolderNames(for: appName) {
                candidates += [
                    (lib.appending(path: "Application Support/\(name)"), "Application support", .explicitOnly),
                    (lib.appending(path: "Caches/\(name)"), "Caches", .explicitOnly),
                    (lib.appending(path: "Logs/\(name)"), "Logs", .explicitOnly),
                    (lib.appending(path: "Application Support/CrashReporter/\(name)"), "Crash reports", .explicitOnly),
                ]
            }
            // Shared containers addressed by the bundle id as whole reverse-DNS
            // labels (`<TEAM>.com.vendor.app`, `group.com.vendor.app`) — a bare
            // substring would hand `com.vendor.app2`'s container to `com.vendor.app`.
            candidates += matching(in: lib.appending(path: "Group Containers"), containing: bundleID, label: "Group container", fm: fm)
                .filter { containsLabels($0.0.lastPathComponent, bundleID) }
                .map { ($0.0, $0.1, SafetyTier.explicitOnly) }
            candidates += launchAgents(in: lib.appending(path: "LaunchAgents"), bundleID: bundleID, appURL: appURL, fm: fm)
        }

        if depth == .deep {
            // Team-identifier app groups, e.g. <TEAMID>.com.vendor.app. These are
            // shared across a vendor's apps, so flag them for review rather than
            // pre-selecting.
            if let teamID, teamID.count >= 6 {
                candidates += matching(in: lib.appending(path: "Group Containers"), containing: teamID, label: "Team app group", fm: fm)
                    .map { ($0.0, $0.1, SafetyTier.review) }
            }
            // Heuristic name matches across plug-in / extension roots. Guarded by a
            // reasonable app-name length so short, common names don't over-match.
            if appName.count >= 4 {
                let heuristicRoots: [(String, String)] = [
                    ("Internet Plug-Ins", "Internet plug-in"),
                    ("PreferencePanes", "Preference pane"),
                    ("QuickLook", "Quick Look extension"),
                    ("Services", "Service"),
                    ("Widgets", "Widget"),
                    ("Screen Savers", "Screen saver"),
                    ("Input Methods", "Input method"),
                    ("Logs/DiagnosticReports", "Crash report"),
                ]
                for (sub, label) in heuristicRoots {
                    candidates += matching(in: lib.appending(path: sub), containing: appName, label: label, fm: fm)
                        .map { ($0.0, $0.1, SafetyTier.review) }
                }
            }
        }

        for (url, label, tier) in candidates {
            let path = url.path
            guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
            seen.insert(path)
            let stats = DirectorySizer.stats(of: url)
            found.append(ScanItem(
                ruleID: "uninstall-\(bundleID)",
                category: .appLeftovers,
                url: url,
                displayName: url.lastPathComponent,
                detail: label,
                size: max(stats.size, 1),
                fileCount: max(stats.fileCount, 1),
                newestModification: stats.newestModification,
                tier: tier,
                domain: .user
            ))
        }
        // High-confidence hits first (so pre-selected items lead the list), then
        // by size within each group.
        return found.sorted { lhs, rhs in
            let lReview = lhs.tier == .review
            let rReview = rhs.tier == .review
            if lReview != rReview { return !lReview }
            return lhs.size > rhs.size
        }
    }

    /// Launch agents that belong to the app being removed.
    ///
    /// A filename is a claim, not proof: anyone can name a plist after
    /// someone else's bundle id, and `com.vendor.app` is a prefix of
    /// `com.vendor.app2`. An agent is pre-selected only when its file is
    /// exactly `<bundleID>.plist`, or the program it launches lives inside the
    /// app bundle being removed. A plist that merely carries the bundle id as
    /// whole labels is offered for review; anything looser is not offered.
    static func launchAgents(in dir: URL, bundleID: String, appURL: URL?, fm: FileManager) -> [(URL, String, SafetyTier)] {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        let exactName = bundleID.lowercased() + ".plist"
        let bundlePrefix = appURL.map { SafetyPolicy.canonical($0.path) + "/" }
        var found: [(URL, String, SafetyTier)] = []
        for entry in entries {
            let name = entry.lastPathComponent.lowercased()
            guard name.hasSuffix(".plist"), !name.hasPrefix("com.apple."),
                  (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if name == exactName {
                found.append((entry, "Launch agent", .explicitOnly))
                continue
            }
            if let bundlePrefix, let program = launchedProgram(entry),
               !program.contains(".."), SafetyPolicy.canonical(program).hasPrefix(bundlePrefix) {
                found.append((entry, "Launch agent (runs from the app)", .explicitOnly))
                continue
            }
            if containsLabels(String(entry.lastPathComponent.dropLast(".plist".count)), bundleID) {
                found.append((entry, "Launch agent — ownership unverified, review", .review))
            }
        }
        return found
    }

    /// `Program`, else the first `ProgramArguments` entry.
    static func launchedProgram(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let program = dict["Program"] as? String { return program }
        return (dict["ProgramArguments"] as? [String])?.first
    }

    /// True when `id`'s dot-separated labels appear, consecutively and whole,
    /// among `name`'s: `ABCD.com.vendor.app` and `com.vendor.app.helper`
    /// contain `com.vendor.app`; `com.vendor.app2` does not.
    static func containsLabels(_ name: String, _ id: String) -> Bool {
        let haystack = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let needle = id.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    private static func matching(in dir: URL, containing needle: String, label: String, fm: FileManager) -> [(URL, String)] {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let lowered = needle.lowercased()
        return entries
            .filter { $0.lastPathComponent.lowercased().contains(lowered) }
            .map { ($0, label) }
    }
}

// MARK: - Orphan scanner

/// Finds data left behind by apps that are no longer installed.
///
/// Three passes, deliberately ordered from most to least certain:
///  1. **Reverse-DNS residue** — entries literally named `com.vendor.app`.
///  2. **Name-style folders** (`AppResidueScanner`) — "Figma", the way Electron
///     and many native apps actually name their data.
///  3. **Stale subfolders inside a live vendor folder** — "Adobe/AcroCef".
///
/// Everything emitted is `.review`: surfaced, never pre-selected, never
/// auto-trimmed.
public enum OrphanScanner {

    public struct Result: Sendable {
        public let items: [ScanItem]
        /// Leftovers that were found but cannot be cleaned yet, because a
        /// process is still executing from inside them.
        public let blocked: [LaunchItemFinding]

        public init(items: [ScanItem], blocked: [LaunchItemFinding]) {
            self.items = items
            self.blocked = blocked
        }
    }

    /// Primary entry point. `index` carries everything known about installed and
    /// running apps, including an injectable LaunchServices lookup, so the whole
    /// scan is a pure function of its inputs and testable against a fixture home.
    public static func scanDetailed(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        index: InstalledAppIndex,
        policy: SafetyPolicy? = nil,
        includeNameStyleFolders: Bool = true
    ) -> Result {
        let policy = policy ?? SafetyPolicy(home: home)
        let residue = ResidueIndex.build(home: home)

        var output = AppResidueScanner.Output()
        if includeNameStyleFolders {
            output = AppResidueScanner.scan(home: home, index: index, residue: residue, policy: policy)
        }
        // Paths a cluster already offers must not be offered a second time by
        // the reverse-DNS pass — the tests assert every path appears once.
        let claimed = Set(output.items.map { SafetyPolicy.canonical($0.url.path) })
        let extra = reverseDNSItems(
            home: home, index: index, policy: policy, residue: residue, claiming: claimed
        )
        return Result(
            items: (output.items + extra).sorted { $0.size > $1.size },
            blocked: output.blocked
        )
    }

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        index: InstalledAppIndex,
        policy: SafetyPolicy? = nil,
        includeNameStyleFolders: Bool = true
    ) -> [ScanItem] {
        scanDetailed(home: home, index: index, policy: policy,
                     includeNameStyleFolders: includeNameStyleFolders).items
    }

    /// Kept for callers (and tests) that only have the two id sets. Runs the
    /// reverse-DNS pass alone.
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedBundleIDs: Set<String>,
        runningBundleIDs: Set<String>
    ) -> [ScanItem] {
        let index = InstalledAppIndex(bundleIDs: installedBundleIDs, runningBundleIDs: runningBundleIDs)
        return scan(home: home, index: index, includeNameStyleFolders: false)
    }

    /// Pass 1. Only flags entries whose name is a reverse-DNS bundle id, never
    /// Apple ids, never ids of installed or running apps.
    static func reverseDNSItems(
        home: URL,
        index: InstalledAppIndex,
        policy: SafetyPolicy,
        residue: ResidueIndex,
        claiming claimed: Set<String>
    ) -> [ScanItem] {
        let fm = FileManager()
        let lib = home.appending(path: "Library")
        let roots: [(URL, Bool)] = [
            (lib.appending(path: "Application Support"), false),
            (lib.appending(path: "Caches"), false),
            (lib.appending(path: "Containers"), false),
            (lib.appending(path: "Saved Application State"), false),
            (lib.appending(path: "HTTPStorages"), false),
            (lib.appending(path: "WebKit"), false),
            (lib.appending(path: "Preferences"), true),
        ]

        // Vendor prefixes (first two reverse-DNS components) of installed and
        // running apps. Helpers, updaters and extensions of an active app carry
        // a DIFFERENT bundle id (e.g. com.google.Keystone for Chrome), so an
        // exact-id check alone would flag them as orphans and let the user trash
        // live data. Skipping the whole vendor prefix is the safe, conservative
        // choice for a delete tool.
        let activeVendors = Set((index.bundleIDs.union(index.runningBundleIDs)).compactMap(vendorPrefix))

        var items: [ScanItem] = []
        for (root, isPreferences) in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                guard !Task.isCancelled else { return items }
                var name = entry.lastPathComponent
                if isPreferences {
                    guard name.hasSuffix(".plist") else { continue }
                    name = String(name.dropLast(6))
                }
                if name.hasSuffix(".savedState") { name = String(name.dropLast(11)) }
                let lowered = name.lowercased()
                // App-group entries are named "group.<bundle id>". Without
                // stripping that prefix the vendor is read as "group.com", so
                // an installed app's group preferences look orphaned — e.g.
                // group.com.nordvpn.macos.firebase while NordVPN is installed.
                let identity = lowered.hasPrefix("group.") ? String(lowered.dropFirst(6)) : lowered

                guard looksLikeBundleID(name),
                      !identity.hasPrefix("com.apple."),
                      !index.bundleIDs.contains(identity),
                      !index.runningBundleIDs.contains(identity),
                      !(vendorPrefix(identity).map { activeVendors.contains($0) } ?? false),
                      // The vendor prefix alone misses publishers whose bundle
                      // id doesn't match their app name: Dropbox ships as
                      // com.getdropbox.dropbox, so its own updater
                      // (com.dropbox.DropboxMacUpdate) reads as orphaned. Match
                      // the vendor component against installed app names too.
                      !(ResidueIndex.vendorToken(identity).map { index.appTokens.contains($0) } ?? false),
                      !claimed.contains(SafetyPolicy.canonical(entry.path)),
                      !policy.isProtected(entry),
                      // A launchd job's own preferences and data. It has no
                      // .app bundle, so it looks orphaned while being live.
                      !residue.isLiveLaunchLabel(identity),
                      !BundleProtection.isDataSensitive(identity),
                      !residue.isReferencedByLaunchItem(entry),
                      // An app that stages a copy of itself inside the user's
                      // Library still resolves through LaunchServices; that is
                      // not an installation. See AppResidueScanner.
                      !AppResidueScanner.isInstalledElsewhere(identity, home: home, candidate: nil, index: index)
                else { continue }

                let stats = DirectorySizer.stats(of: entry)
                guard stats.size > 0 else { continue }
                items.append(ScanItem(
                    ruleID: "orphan",
                    category: .appLeftovers,
                    url: entry,
                    displayName: name,
                    detail: "in \(root.lastPathComponent)",
                    size: stats.size,
                    fileCount: stats.fileCount,
                    newestModification: stats.newestModification,
                    tier: .review,
                    domain: .user,
                    group: ResidueIndex.vendorToken(identity),
                    identity: FileIdentity.current(of: entry)
                ))
            }
        }
        return items
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        guard !name.contains(" "), name.count > 5 else { return false }
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    /// First two reverse-DNS components, e.g. "com.google.Keystone" -> "com.google".
    static func vendorPrefix(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts[0].lowercased() + "." + parts[1].lowercased()
    }

    static func appURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
