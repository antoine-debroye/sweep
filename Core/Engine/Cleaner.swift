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

    public init(
        policy: SafetyPolicy,
        whitelist: [String] = [],
        trashRemover: FileRemover = TrashRemover(),
        permanentRemover: FileRemover = PermanentRemover(),
        privileged: PrivilegedRemoving? = nil
    ) {
        self.policy = policy
        self.whitelist = whitelist
        self.trashRemover = trashRemover
        self.permanentRemover = permanentRemover
        self.privileged = privileged
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
