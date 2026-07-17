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
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let name = (fm.displayName(atPath: entry.path) as NSString).deletingPathExtension
                let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
                let lastUsed = lastUsedDate(for: entry)
                apps.append(InstalledApp(url: entry, name: name, bundleID: bundleID, version: version, size: nil, lastUsed: lastUsed))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

/// Locates everything an app scattered across the user's Library (and a few
/// system locations), mirroring mole's uninstaller coverage.
public enum LeftoverFinder {
    public static func find(
        bundleID: String,
        appName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ScanItem] {
        let fm = FileManager()
        let lib = home.appending(path: "Library")
        var found: [ScanItem] = []
        var seen = Set<String>()

        // Locations addressed directly by bundle id or app name.
        var candidates: [(URL, String)] = [
            (lib.appending(path: "Application Support/\(appName)"), "Application support"),
            (lib.appending(path: "Application Support/\(bundleID)"), "Application support"),
            (lib.appending(path: "Caches/\(bundleID)"), "Caches"),
            (lib.appending(path: "Caches/\(appName)"), "Caches"),
            (lib.appending(path: "Preferences/\(bundleID).plist"), "Preferences"),
            (lib.appending(path: "Logs/\(appName)"), "Logs"),
            (lib.appending(path: "Logs/\(bundleID)"), "Logs"),
            (lib.appending(path: "Containers/\(bundleID)"), "Container"),
            (lib.appending(path: "Saved Application State/\(bundleID).savedState"), "Saved state"),
            (lib.appending(path: "WebKit/\(bundleID)"), "WebKit data"),
            (lib.appending(path: "HTTPStorages/\(bundleID)"), "HTTP storage"),
            (lib.appending(path: "Cookies/\(bundleID).binarycookies"), "Cookies"),
            (lib.appending(path: "Application Scripts/\(bundleID)"), "App scripts"),
        ]

        // Group containers and launch agents need a prefix match.
        candidates += matching(in: lib.appending(path: "Group Containers"), containing: bundleID, label: "Group container", fm: fm)
        candidates += matching(in: lib.appending(path: "LaunchAgents"), containing: bundleID, label: "Launch agent", fm: fm)

        for (url, label) in candidates {
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
                tier: .explicitOnly,
                domain: .user
            ))
        }
        return found.sorted { $0.size > $1.size }
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
