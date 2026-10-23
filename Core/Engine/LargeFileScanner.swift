import Foundation

public struct LargeFile: Sendable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modified: Date?
    public let created: Date?
    public let lastAccessed: Date?
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    /// Anything before this is almost certainly broken metadata, not a real date.
    /// Some files report a near-epoch `contentModificationDate` (shown as
    /// "46 yr ago"); we treat those as unknown so date-sorting stays meaningful.
    public static let plausibleDateFloor = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01

    /// The most trustworthy human date: modification if plausible, else creation,
    /// else `nil` (rendered as "Unknown date").
    public var displayDate: Date? {
        if let modified, modified >= Self.plausibleDateFloor { return modified }
        if let created, created >= Self.plausibleDateFloor { return created }
        return nil
    }
}

/// Finds big files under the user's home. Read-only discovery: deleting is
/// always an explicit, per-file user action, so protected areas are excluded
/// from the walk entirely (this scanner is about junk, not Documents).
public enum LargeFileScanner {
    /// Directories not worth walking for "large files": build output and tool
    /// caches (their big files are regenerable and belong to Dev Cleaner, not
    /// here), plus version-control internals. Skipping them keeps the walk fast
    /// and off the volatile trees a developer is actively writing to.
    static let pruneDirNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "target", "build", "dist",
        ".next", ".nuxt", ".turbo", ".parcel-cache", "Pods", "DerivedData",
        ".gradle", "venv", ".venv", "__pycache__", ".tox", ".dart_tool", ".cache", "Caches",
        ".ollama", ".lmstudio",
    ]

    public static func scan(
        roots: [URL],
        minSize: Int64,
        policy: SafetyPolicy,
        limit: Int = 400
    ) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                walk(roots: roots, minSize: minSize, policy: policy, limit: limit) { file in
                    continuation.yield(file)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synchronous walk (NSDirectoryEnumerator cannot be iterated from async
    /// contexts). Checks Task.isCancelled cooperatively.
    private static func walk(
        roots: [URL],
        minSize: Int64,
        policy: SafetyPolicy,
        limit: Int,
        emit: (LargeFile) -> Void
    ) {
        let fm = FileManager()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .contentAccessDateKey, .isPackageKey,
        ]
        var emitted = 0
        let libraryPath = policy.home.appending(path: "Library").path

        for root in roots {
            guard emitted < limit, fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited % 256 == 0, Task.isCancelled { return }
                if emitted >= limit { break }

                let name = url.lastPathComponent
                if name.hasPrefix(".") && enumerator.level == 1 {
                    enumerator.skipDescendants()
                    continue
                }
                if pruneDirNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if policy.isProtected(url) {
                    enumerator.skipDescendants()
                    continue
                }
                // Skip the Library subtree: rule-based cleaning owns it.
                if url.path == libraryPath {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                guard size >= minSize else { continue }
                emitted += 1
                emit(LargeFile(
                    url: url,
                    size: size,
                    modified: values.contentModificationDate,
                    created: values.creationDate,
                    lastAccessed: values.contentAccessDate
                ))
            }
        }
    }
}

// MARK: - Project artifacts

/// Finds regenerable build artifacts (node_modules, target, .build, …) inside
/// the user's dev folders.
public enum ProjectArtifactScanner {
    public static let artifactNames: Set<String> = [
        "node_modules", ".build", "target", "dist", "build",
        ".next", ".nuxt", ".turbo", ".parcel-cache",
        "venv", ".venv", "__pycache__", ".tox", ".dart_tool",
        "Pods", "DerivedData", ".gradle",
    ]

    public static let ruleID = "project-artifacts"

    public static func scan(
        devFolders: [URL],
        minAgeDays: Int,
        policy: SafetyPolicy,
        git: ArtifactGitGuard.GitRunner? = ArtifactGitGuard.defaultGit
    ) -> [ScanItem] {
        // Phase 1 (cheap, sequential): walk the dev folders and collect the
        // artifact directories. Phase 2 (the expensive part — sizing tens of
        // thousands of files per node_modules) runs concurrently per artifact.
        let candidates = artifactCandidates(devFolders: devFolders, policy: policy)
        guard !candidates.isEmpty, !Task.isCancelled else { return [] }

        let results = ConcurrentResults<ScanItem>()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            guard !results.cancelled else { return }
            let url = candidates[index]
            // Before sizing: a checked-in `build/` is not build output.
            guard ArtifactGitGuard.verdict(for: url, git: git).isRegenerable else { return }
            let stats = DirectorySizer.stats(of: url)
            // A repository anywhere inside (a checkout under Flutter's build/,
            // a vendored dependency) means it isn't disposable output. The
            // shallow check above can't see that deep; the sizing walk can.
            guard stats.size > 0, !stats.containsGitMetadata else { return }
            if minAgeDays > 0 {
                let newest = stats.newestModification ?? .distantPast
                guard Date().timeIntervalSince(newest) / 86_400 >= Double(minAgeDays) else { return }
            }
            let name = url.lastPathComponent
            let project = url.deletingLastPathComponent().lastPathComponent
            results.append(ScanItem(
                ruleID: ruleID,
                category: .projectArtifacts,
                url: url,
                displayName: "\(project)/\(name)",
                detail: "regenerates on next build/install",
                size: stats.size,
                fileCount: stats.fileCount,
                newestModification: stats.newestModification,
                tier: .review,
                domain: .user
            ))
        }
        return results.items.sorted { $0.size > $1.size }
    }

    /// Artifact directories under the dev folders (max depth 5, hidden
    /// folders pruned, artifacts themselves never descended into).
    static func artifactCandidates(devFolders: [URL], policy: SafetyPolicy) -> [URL] {
        let fm = FileManager()
        var candidates: [URL] = []
        for folder in devFolders {
            guard fm.fileExists(atPath: folder.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return candidates }
                if enumerator.level > 5 {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                if name.hasPrefix(".") && !artifactNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard artifactNames.contains(name) else { continue }
                enumerator.skipDescendants()
                guard !policy.isProtected(url) else { continue }
                candidates.append(url)
            }
        }
        return candidates
    }
}

/// Lock-protected collector for `concurrentPerform` workers. Sizing runs
/// outside any Task, so cancellation is sampled once up front and re-checked
/// by workers through `cancelled`.
final class ConcurrentResults<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    private let cancelFlag: Bool

    init() { cancelFlag = Task.isCancelled }

    var cancelled: Bool { cancelFlag }

    func append(_ item: T) {
        lock.lock()
        storage.append(item)
        lock.unlock()
    }

    var items: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
