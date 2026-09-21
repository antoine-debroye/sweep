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
        stats(of: url, ignoringHiddenEntries: false)
    }

    /// As `stats(of:)`, but when `ignoringHiddenEntries` is true the
    /// `newestModification` date is computed from **non-hidden regular files
    /// only** — directory timestamps and anything under a dot-prefixed path
    /// component are excluded.
    ///
    /// Why: Finder writes `.DS_Store` into every folder the user browses, which
    /// bumps both the file's and the folder's modification date to "now". An age
    /// gate reading the raw newest-modification therefore believes a long-dead
    /// leftover folder was touched today, purely because someone looked at it.
    ///
    /// `size` and `fileCount` still count every file, hidden included — those
    /// bytes are real and would be deleted.
    public static func stats(of url: URL, ignoringHiddenEntries: Bool) -> DirectoryStats {
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
                if !ignoringHiddenEntries || !url.lastPathComponent.hasPrefix(".") {
                    stats.newestModification = values.contentModificationDate
                }
            }
            return stats
        }

        if !ignoringHiddenEntries,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
            stats.newestModification = values.contentModificationDate
        }

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return stats
        }

        let rootComponentCount = url.standardizedFileURL.pathComponents.count
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 512 == 0, Task.isCancelled { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            let isRegularFile = values.isRegularFile == true
            if isRegularFile {
                stats.size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                stats.fileCount += 1
            }
            if ignoringHiddenEntries {
                guard isRegularFile, !isHidden(child, belowComponentCount: rootComponentCount) else { continue }
            }
            if let modified = values.contentModificationDate {
                if stats.newestModification == nil || modified > stats.newestModification! {
                    stats.newestModification = modified
                }
            }
        }
        return stats
    }

    /// True when any path component of `url` *below* the scan root is
    /// dot-prefixed, so files buried inside `.git` or `.cache` are skipped too.
    private static func isHidden(_ url: URL, belowComponentCount rootComponentCount: Int) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponentCount else { return false }
        return components[rootComponentCount...].contains { $0.hasPrefix(".") }
    }
}
