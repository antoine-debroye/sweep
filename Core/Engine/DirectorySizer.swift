import Foundation

public struct DirectoryStats: Sendable {
    public var size: Int64 = 0
    public var fileCount: Int = 0
    public var newestModification: Date?
}

public enum DirectorySizer {
    /// Recursively computes allocated size, file count, and the newest
    /// content-modification date under `url`. Symlinks are not followed.
    /// Checks for task cancellation periodically.
    public static func stats(of url: URL) -> DirectoryStats {
        let fm = FileManager()
        var stats = DirectoryStats()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey,
        ]

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return stats }

        if !isDirectory.boolValue {
            if let values = try? url.resourceValues(forKeys: Set(keys)) {
                stats.size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                stats.fileCount = 1
                stats.newestModification = values.contentModificationDate
            }
            return stats
        }

        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            stats.newestModification = values.contentModificationDate
        }

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return stats
        }

        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 512 == 0, Task.isCancelled { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                stats.size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                stats.fileCount += 1
            }
            if let modified = values.contentModificationDate {
                if stats.newestModification == nil || modified > stats.newestModification! {
                    stats.newestModification = modified
                }
            }
        }
        return stats
    }
}
