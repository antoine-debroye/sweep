import Foundation

/// Rule-driven junk scanner. Read-only: it enumerates and sizes, never deletes.
/// Categories are scanned concurrently; every produced item has passed the
/// safety policy, the user whitelist, the per-rule exclude list, and the
/// per-rule age gate.
public struct ScanEngine: Sendable {
    public let policy: SafetyPolicy
    public let whitelist: [String]
    /// Bundle ids of currently running apps, used by rules that skip live data.
    public let runningBundleIDs: Set<String>

    public init(policy: SafetyPolicy, whitelist: [String] = [], runningBundleIDs: Set<String> = []) {
        self.policy = policy
        self.whitelist = whitelist
        self.runningBundleIDs = runningBundleIDs
    }

    public func scan(rules: [CleaningRule]) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = Date()
                let clock = ContinuousClock.now
                var allItems: [ScanItem] = []

                let byCategory = Dictionary(grouping: rules, by: \.category)
                await withTaskGroup(of: [ScanItem].self) { group in
                    for (category, categoryRules) in byCategory {
                        continuation.yield(.categoryStarted(category))
                        group.addTask {
                            var items: [ScanItem] = []
                            for rule in categoryRules {
                                guard !Task.isCancelled else { break }
                                for item in self.items(for: rule) {
                                    items.append(item)
                                    continuation.yield(.item(item))
                                }
                            }
                            continuation.yield(.categoryFinished(category))
                            return items
                        }
                    }
                    for await items in group {
                        allItems.append(contentsOf: items)
                    }
                }

                let duration = clock.duration(to: .now)
                let report = ScanReport(
                    items: allItems,
                    startedAt: startedAt,
                    duration: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                )
                continuation.yield(.finished(report))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience for non-interactive callers (auto-trim, tests).
    public func scanReport(rules: [CleaningRule]) async -> ScanReport {
        for await event in scan(rules: rules) {
            if case .finished(let report) = event { return report }
        }
        return ScanReport(items: [], startedAt: Date(), duration: 0)
    }

    // MARK: - Rule expansion

    func items(for rule: CleaningRule) -> [ScanItem] {
        let fm = FileManager()
        var results: [ScanItem] = []

        for root in rule.paths {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard !policy.isProtected(root) || rule.contentsOnly else { continue }

            let candidates: [URL]
            if rule.contentsOnly {
                candidates = children(of: root, rule: rule, fm: fm)
            } else {
                candidates = [root]
            }

            for candidate in candidates {
                guard !Task.isCancelled else { return results }
                guard passesGates(candidate, rule: rule) else { continue }
                if rule.skipRunningApps,
                   RunningAppGuard.isOwnedByRunningApp(candidate, running: runningBundleIDs) {
                    continue
                }
                let stats = DirectorySizer.stats(of: candidate)
                guard stats.size > 0 else { continue }
                if let item = makeItem(candidate, rule: rule, stats: stats) {
                    results.append(item)
                }
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    private func children(of root: URL, rule: CleaningRule, fm: FileManager) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return [] }

        return entries.filter { entry in
            let name = entry.lastPathComponent.lowercased()
            if rule.excludeNames.contains(name) { return false }
            if name == ".ds_store" { return false }
            if let extensions = rule.extensions {
                guard extensions.contains(entry.pathExtension.lowercased()) else { return false }
            }
            if rule.filesOnly {
                let isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { return false }
            }
            return true
        }
    }

    private func passesGates(_ url: URL, rule: CleaningRule) -> Bool {
        if policy.isProtected(url) { return false }
        if SafetyPolicy.isWhitelisted(url, whitelist: whitelist) { return false }
        // Never touch iCloud-managed items: no data loss, no surprise downloads.
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return false
        }
        return true
    }

    private func makeItem(_ url: URL, rule: CleaningRule, stats: DirectoryStats) -> ScanItem? {
        if rule.minAgeDays > 0 {
            let newest = stats.newestModification ?? .distantPast
            let ageDays = Date().timeIntervalSince(newest) / 86_400
            guard ageDays >= Double(rule.minAgeDays) else { return nil }
        }
        let name = ScanEngine.displayName(for: url)
        let detailParts: [String] = [
            stats.fileCount == 1 ? "1 file" : "\(stats.fileCount) files",
            stats.newestModification.map { "last change \($0.sweepRelative)" } ?? "",
        ].filter { !$0.isEmpty }

        return ScanItem(
            ruleID: rule.id,
            category: rule.category,
            url: url,
            displayName: name,
            detail: detailParts.joined(separator: " · "),
            size: stats.size,
            fileCount: stats.fileCount,
            newestModification: stats.newestModification,
            tier: rule.tier,
            domain: rule.domain,
            forcePermanent: rule.forcePermanent
        )
    }

    static func displayName(for url: URL) -> String {
        let component = url.lastPathComponent
        // Friendlier names for common cache folder shapes.
        switch component.lowercased() {
        case "chrome": return "Chrome"
        case "caches" where url.path.lowercased().contains("safari"): return "Safari"
        default: return component
        }
    }
}
