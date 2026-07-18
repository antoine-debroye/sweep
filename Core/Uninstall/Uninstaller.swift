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
            for entry in entries where entry.pathExtension == "app" {
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
    public static func find(
        bundleID: String,
        appName: String,
        teamID: String? = nil,
        depth: MatchDepth = .enhanced,
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
            .map { ($0.0, $0.1, SafetyTier.explicitOnly) }

        if depth == .enhanced || depth == .deep {
            candidates += [
                (lib.appending(path: "Application Support/\(appName)"), "Application support", .explicitOnly),
                (lib.appending(path: "Caches/\(appName)"), "Caches", .explicitOnly),
                (lib.appending(path: "Logs/\(appName)"), "Logs", .explicitOnly),
                (lib.appending(path: "Application Support/CrashReporter/\(appName)"), "Crash reports", .explicitOnly),
            ]
            // Shared containers and launch agents addressed by a bundle-id prefix.
            candidates += matching(in: lib.appending(path: "Group Containers"), containing: bundleID, label: "Group container", fm: fm)
                .map { ($0.0, $0.1, SafetyTier.explicitOnly) }
            candidates += matching(in: lib.appending(path: "LaunchAgents"), containing: bundleID, label: "Launch agent", fm: fm)
                .map { ($0.0, $0.1, SafetyTier.explicitOnly) }
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

    private static func matching(in dir: URL, containing needle: String, label: String, fm: FileManager) -> [(URL, String)] {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let lowered = needle.lowercased()
        return entries
            .filter { $0.lastPathComponent.lowercased().contains(lowered) }
            .map { ($0, label) }
    }
}

// MARK: - Orphan scanner

/// Finds data left behind by apps that are no longer installed. Deliberately
/// conservative: only flags entries whose name is a reverse-DNS bundle id,
/// never Apple ids, never ids of installed or running apps.
public enum OrphanScanner {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedBundleIDs: Set<String>,
        runningBundleIDs: Set<String>
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
        let activeVendors = Set((installedBundleIDs.union(runningBundleIDs)).compactMap(vendorPrefix))

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

                guard looksLikeBundleID(name),
                      !name.hasPrefix("com.apple."),
                      !installedBundleIDs.contains(name),
                      !runningBundleIDs.contains(name),
                      !(vendorPrefix(name).map { activeVendors.contains($0) } ?? false),
                      appURL(forBundleID: name) == nil else { continue }

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
                    domain: .user
                ))
            }
        }
        return items.sorted { $0.size > $1.size }
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
