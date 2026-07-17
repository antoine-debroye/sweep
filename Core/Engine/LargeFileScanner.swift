import Foundation

public struct LargeFile: Sendable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modified: Date?
    public let lastAccessed: Date?
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

/// Finds big files under the user's home. Read-only discovery: deleting is
/// always an explicit, per-file user action, so protected areas are excluded
/// from the walk entirely (this scanner is about junk, not Documents).
public enum LargeFileScanner {
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
            .contentModificationDateKey, .contentAccessDateKey, .isPackageKey,
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
                    lastAccessed: values.contentAccessDate
                ))
            }
        }
    }
}

// MARK: - Project artifacts

/// Finds regenerable build artifacts (node_modules, target, .build, …) inside
/// the user's dev folders, mirroring mole's `mo purge`.
public enum ProjectArtifactScanner {
    public static let artifactNames: Set<String> = [
        "node_modules", ".build", "target", "dist", "build",
        ".next", ".nuxt", ".turbo", ".parcel-cache",
        "venv", ".venv", "__pycache__", ".tox",
        "Pods", "DerivedData", ".gradle",
    ]

    public static func scan(
        devFolders: [URL],
        minAgeDays: Int,
        policy: SafetyPolicy
    ) -> [ScanItem] {
        let fm = FileManager()
        var items: [ScanItem] = []

        for folder in devFolders {
            guard fm.fileExists(atPath: folder.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard !Task.isCancelled else { return items }
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

                let stats = DirectorySizer.stats(of: url)
                guard stats.size > 0 else { continue }
                if minAgeDays > 0 {
                    let newest = stats.newestModification ?? .distantPast
                    guard Date().timeIntervalSince(newest) / 86_400 >= Double(minAgeDays) else { continue }
                }
                let project = url.deletingLastPathComponent().lastPathComponent
                items.append(ScanItem(
                    ruleID: "project-artifacts",
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
        }
        return items.sorted { $0.size > $1.size }
    }
}
