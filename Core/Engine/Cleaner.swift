import Foundation

/// Abstraction over "make this file go away" so tests can record instead of
/// delete, and so system-domain paths can route through the privileged helper.
public protocol FileRemover: Sendable {
    /// Removes the item; returns its new Trash location when applicable.
    func remove(_ url: URL) throws -> URL?
}

public struct TrashRemover: FileRemover {
    public init() {}
    public func remove(_ url: URL) throws -> URL? {
        var trashedURL: NSURL?
        try FileManager().trashItem(at: url, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }
}

public struct PermanentRemover: FileRemover {
    public init() {}
    public func remove(_ url: URL) throws -> URL? {
        try FileManager().removeItem(at: url)
        return nil
    }
}

/// Routes system-domain deletions to whatever privileged mechanism is
/// available. Implemented by PrivilegeBroker in the app layer.
public protocol PrivilegedRemoving: Sendable {
    func removePrivileged(paths: [String]) async throws -> String
}

public struct CleanProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentName: String
    public let freedSoFar: Int64
}

/// Executes a clean. Every item is re-checked against the safety policy right
/// before removal — the cleaner refuses protected paths even if a broken
/// caller passed one in.
public struct Cleaner: Sendable {
    public let policy: SafetyPolicy
    public let whitelist: [String]
    public let trashRemover: FileRemover
    public let permanentRemover: FileRemover
    public let privileged: PrivilegedRemoving?
    public let liveness: FileLiveness

    public init(
        policy: SafetyPolicy,
        whitelist: [String] = [],
        trashRemover: FileRemover = TrashRemover(),
        permanentRemover: FileRemover = PermanentRemover(),
        privileged: PrivilegedRemoving? = nil,
        liveness: FileLiveness = FileLiveness()
    ) {
        self.policy = policy
        self.whitelist = whitelist
        self.trashRemover = trashRemover
        self.permanentRemover = permanentRemover
        self.privileged = privileged
        self.liveness = liveness
    }

    /// Rules whose targets are, by their nature, things a process may be
    /// actively writing — so an inconclusive liveness probe must keep them
    /// rather than wave them through.
    ///
    /// `incomplete-downloads` is the case that proves it: a `.crdownload` or
    /// `<sha>--<name>.incomplete` older than the age gate can still belong to a
    /// transfer that is resuming right now, and deleting it loses the transfer.
    static let rulesRequiringConclusiveIdle: Set<String> = [
        "incomplete-downloads", "incomplete-brew-downloads", "codex-incomplete-runtimes",
        "user-temp", "darwin-user-caches",
    ]

    static func requiresConclusiveIdle(_ item: ScanItem) -> Bool {
        if rulesRequiringConclusiveIdle.contains(item.ruleID) { return true }
        let name = item.url.lastPathComponent.lowercased()
        if ["download", "crdownload", "part", "partial", "incomplete", "tmp"]
            .contains(item.url.pathExtension.lowercased()) { return true }
        // A live SQLite database is the other classic: the -shm is only present
        // while a connection is open.
        return name.hasSuffix(".sqlite") || name.hasSuffix(".db")
            || name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix(".vscdb")
    }

    /// True only when the URL is inside a real Trash directory: the user's
    /// `~/.Trash` or a per-volume `/.Trashes/<uid>`. Anchored to a path
    /// component so folders merely named ".trashcan" etc. don't match.
    static func isInTrash(_ url: URL) -> Bool {
        let components = url.pathComponents.map { $0.lowercased() }
        if components.contains(".trash") { return true }
        if let idx = components.firstIndex(of: ".trashes"), idx + 1 < components.count { return true }
        return false
    }

    public func clean(
        items: [ScanItem],
        source: CleanSource,
        permanentDelete: Bool,
        progress: (@Sendable (CleanProgress) -> Void)? = nil
    ) async -> CleanSession {
        var cleaned: [CleanedItem] = []
        var errors: [String] = []
        var freed: Int64 = 0
        let userItems = items.filter { $0.domain == .user }
        let systemItems = items.filter { $0.domain == .system }
        let total = items.count
        var completed = 0

        // One batched probe for the whole run: which of these is a process
        // holding open right now? Deleting data out from under a live process
        // is not a clean-up, and no age gate can tell you this.
        let verdicts = await liveness.verdicts(for: userItems.map(\.url))

        for item in userItems {
            guard !Task.isCancelled else { break }
            guard !policy.isProtected(item.url) else {
                errors.append("Refused protected path: \(item.url.path)")
                continue
            }
            // Defense in depth: honor the user's whitelist at the deletion
            // boundary too, not only in the scanner. Callers that build items
            // outside the gated scanner (Large Files, Uninstaller) reach here
            // directly, so re-checking closes that gap.
            guard !SafetyPolicy.isWhitelisted(item.url, whitelist: whitelist) else {
                errors.append("Skipped (whitelisted): \(item.url.path)")
                continue
            }
            // Items already in the Trash are removed permanently — "trashing the
            // Trash" would just shuffle them around. Anchor the check to the
            // real Trash locations so an unrelated path that merely contains
            // ".trash" isn't silently force-deleted.
            switch verdicts[item.url.path] {
            case .inUse(let command):
                let blocker = command.map { " (\($0))" } ?? ""
                errors.append("Skipped, still in use\(blocker): \(item.url.path)")
                continue
            case .unknown(let reason) where Cleaner.requiresConclusiveIdle(item):
                errors.append("Skipped, could not confirm it is idle (\(reason)): \(item.url.path)")
                continue
            default:
                break
            }

            // Re-bind identity immediately before removal. The item was
            // measured during the scan, possibly minutes ago; if the path now
            // points at a different object it was renamed and recreated in
            // between, and the user never reviewed this one.
            if let scanned = item.identity {
                guard let now = FileIdentity.current(of: item.url) else {
                    errors.append("Skipped, no longer exists: \(item.url.path)")
                    continue
                }
                guard now == scanned else {
                    errors.append("Skipped, changed since the scan: \(item.url.path)")
                    continue
                }
            }

            let inTrash = Cleaner.isInTrash(item.url)
            let usePermanent = permanentDelete || item.forcePermanent || inTrash
            let remover = usePermanent ? permanentRemover : trashRemover
            do {
                let trashURL = try remover.remove(item.url)
                freed += item.size
                cleaned.append(CleanedItem(
                    originalPath: item.url.path,
                    trashPath: trashURL?.path,
                    size: item.size,
                    displayName: item.displayName,
                    category: item.category
                ))
            } catch {
                errors.append("\(item.displayName): \(error.localizedDescription)")
            }
            completed += 1
            progress?(CleanProgress(completed: completed, total: total, currentName: item.displayName, freedSoFar: freed))
        }

        if !systemItems.isEmpty {
            let validPaths = systemItems
                .filter { !policy.isProtected($0.url) && PrivilegedPathPolicy.isAllowed($0.url.path) }
                .map { $0.url.path }
            if let privileged, !validPaths.isEmpty {
                do {
                    _ = try await privileged.removePrivileged(paths: validPaths)
                    for item in systemItems where validPaths.contains(item.url.path) {
                        freed += item.size
                        cleaned.append(CleanedItem(
                            originalPath: item.url.path,
                            trashPath: nil,
                            size: item.size,
                            displayName: item.displayName,
                            category: item.category
                        ))
                    }
                } catch {
                    errors.append("System files: \(error.localizedDescription)")
                }
            } else if privileged == nil {
                errors.append("System files skipped: no administrator access configured.")
            }
            completed += systemItems.count
            progress?(CleanProgress(completed: completed, total: total, currentName: "System files", freedSoFar: freed))
        }

        return CleanSession(date: Date(), source: source, items: cleaned, errors: errors)
    }
}
