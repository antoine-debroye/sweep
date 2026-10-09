import Foundation

/// One entry in the disk-usage tree: a folder or file with its on-disk size and
/// a safety/cloud classification. `allocatedSize` is real blocks used on the
/// volume (what freeing it actually reclaims); `logicalSize` is the apparent
/// size — the gap between them reveals cloud "online-only" placeholders.
public struct DiskNode: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let fileCount: Int
    public let newestModification: Date?
    public let kind: DiskNodeKind
    /// Part of the folder could not be read, so `allocatedSize` is a lower
    /// bound. Shown as such rather than as a confident (and wrong) total.
    public let isPartial: Bool

    public var id: String { url.path }

    public init(url: URL, name: String, isDirectory: Bool, allocatedSize: Int64,
                logicalSize: Int64, fileCount: Int, newestModification: Date?, kind: DiskNodeKind,
                isPartial: Bool = false) {
        self.isPartial = isPartial
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
        self.newestModification = newestModification
        self.kind = kind
    }
}

/// How a node may be acted on. Cloud items are never deletable through Sweep
/// (deleting a materialized cloud file removes the cloud copy too) — they can
/// only be *offloaded* (evict the local copy, keep the original online).
public enum DiskNodeKind: Sendable, Equatable {
    case safeToDelete                        // regenerable (caches, build output…)
    case review                              // real user data — delete deliberately
    case protectedPath                       // hard-protected, never deletable
    case cloudOffloadable(localBytes: Int64) // synced + downloaded locally → reclaimable
    case cloudOnlineOnly                     // already online-only → no local space to reclaim

    public var isDeletable: Bool {
        switch self {
        case .safeToDelete, .review: true
        default: false
        }
    }

    public var isCloud: Bool {
        switch self {
        case .cloudOffloadable, .cloudOnlineOnly: true
        default: false
        }
    }

    /// Local bytes reclaimable by offloading (0 unless materialized cloud data).
    public var offloadableBytes: Int64 {
        if case .cloudOffloadable(let bytes) = self { return bytes }
        return 0
    }
}

public enum DiskTreeScanner {
    /// Materialized cloud data below this is treated as noise, not worth flagging.
    static let offloadFloor: Int64 = 1_000_000  // 1 MB

    /// Streams the direct children of `url` as each one is sized and classified, so
    /// the UI can show rows and running totals incrementally instead of waiting for
    /// the whole level. Folders are sized fully (recursively, in parallel), files by
    /// their allocated + logical bytes. Mirrors the AsyncStream + detached-producer
    /// pattern used by `ScanEngine.scan` / `LargeFileScanner.scan`, so the producer
    /// never inherits `@MainActor` isolation.
    public static func stream(of url: URL, policy: SafetyPolicy) -> AsyncStream<DiskNode> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let fm = FileManager()
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .totalFileSizeKey, .fileSizeKey,
                    .contentModificationDateKey, .isUbiquitousItemKey,
                ]
                guard let entries = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: []   // include hidden — dotfolders (.ollama, .cache…) can be huge
                ) else { continuation.finish(); return }

                await withTaskGroup(of: DiskNode?.self) { group in
                    for entry in entries {
                        group.addTask { node(for: entry, keys: keys, policy: policy) }
                    }
                    for await maybe in group {
                        if Task.isCancelled { break }
                        if let node = maybe { continuation.yield(node) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects `stream` into a fully-sized, largest-first array. Preserves the
    /// original one-shot API + sort contract for non-streaming callers and tests.
    public static func children(of url: URL, policy: SafetyPolicy) async -> [DiskNode] {
        var nodes: [DiskNode] = []
        for await node in stream(of: url, policy: policy) { nodes.append(node) }
        nodes.sort { $0.allocatedSize > $1.allocatedSize }
        return nodes
    }

    private static func node(for url: URL, keys: Set<URLResourceKey>, policy: SafetyPolicy) -> DiskNode? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true { return nil }   // don't follow / double-count links

        let isDir = values.isDirectory == true
        let isUbiquitous = values.isUbiquitousItem == true

        let allocated: Int64
        let logical: Int64
        let fileCount: Int
        let newest: Date?
        var partial = false
        if isDir {
            let stats = DirectorySizer.stats(of: url)   // recursive, allocated bytes
            allocated = stats.size
            logical = stats.size
            fileCount = stats.fileCount
            newest = stats.newestModification
            partial = stats.isPartial
        } else {
            allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            logical = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            fileCount = 1
            newest = values.contentModificationDate
        }

        var kind = classify(url: url, allocated: allocated, logical: logical,
                            isUbiquitous: isUbiquitous, policy: policy)
        // "Safe" for a build-output name is a claim that it regenerates; a
        // checked-in `build/` or `dist/` does not, so it drops to Review.
        if kind == .safeToDelete, isDir,
           ProjectArtifactScanner.artifactNames.contains(url.lastPathComponent),
           !ArtifactGitGuard.verdict(for: url).isRegenerable {
            kind = .review
        }

        return DiskNode(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDir,
            allocatedSize: allocated,
            logicalSize: logical,
            fileCount: fileCount,
            newestModification: newest,
            kind: kind,
            isPartial: partial
        )
    }

    /// Pure classifier — no disk access, so it is directly unit-testable.
    public static func classify(url: URL, allocated: Int64, logical: Int64,
                                isUbiquitous: Bool, policy: SafetyPolicy) -> DiskNodeKind {
        let path = url.path
        let isCloud = isUbiquitous
            || path.contains("/Library/CloudStorage/")
            || path.contains("/Library/Mobile Documents/")

        if isCloud {
            // Online-only placeholders report large logical but ~0 allocated bytes.
            // Materialized data (allocated a meaningful fraction of logical, above
            // the noise floor) is what offloading actually reclaims.
            if allocated > offloadFloor && allocated * 4 >= logical {
                return .cloudOffloadable(localBytes: allocated)
            }
            return .cloudOnlineOnly
        }
        if policy.isProtected(url) { return .protectedPath }
        if isSafeToDelete(url) { return .safeToDelete }
        return .review
    }

    /// Conservative allow-list of regenerable locations we're comfortable calling
    /// safe. Anything not matched stays `.review` (delete deliberately).
    static func isSafeToDelete(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ProjectArtifactScanner.artifactNames.contains(name) { return true }
        let safeNames: Set<String> = ["Caches", ".Trash", "DerivedData", ".cache", "tmp"]
        if safeNames.contains(name) { return true }
        let path = url.path
        let safeMarkers = ["/Library/Caches/", "/DerivedData/", "/Library/Developer/Xcode/DerivedData"]
        return safeMarkers.contains { path.contains($0) }
    }
}
