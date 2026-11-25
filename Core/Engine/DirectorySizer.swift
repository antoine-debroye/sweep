import Foundation

public struct DirectoryStats: Sendable {
    public var size: Int64 = 0
    public var fileCount: Int = 0
    public var newestModification: Date?
    /// Entries the walk could not read (permissions, TCC). Non-zero means
    /// `size` is a lower bound, not a measurement.
    public var unreadableEntries: Int = 0
    /// A `.git` entry exists somewhere below the root: the tree holds a
    /// repository, so it is not disposable build output whatever its name.
    public var containsGitMetadata = false

    public var isPartial: Bool { unreadableEntries > 0 }
}

/// Counts walk errors from the enumerator's escaping error handler.
private final class ErrorTally: @unchecked Sendable {
    var count = 0
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
            .contentModificationDateKey, .linkCountKey, .fileResourceIdentifierKey,
            .isVolumeKey,
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

        let errors = ErrorTally()
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
            // An entry that vanished mid-walk was never ours to count; one we
            // could not open is a hole in the measurement.
            if !DirectorySizer.isVanished(error) { errors.count += 1 }
            return true
        }) else {
            stats.unreadableEntries = 1
            return stats
        }

        let rootComponentCount = url.standardizedFileURL.pathComponents.count
        // Hard links share their blocks: count each multiply-linked file once,
        // as `du` does, or a pnpm-style tree reads as several times its size.
        var seenLinked = Set<NSObject>()
        let keySet = Set(keys)   // built once, not per entry
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 512 == 0, Task.isCancelled { break }
            if child.lastPathComponent == ".git" { stats.containsGitMetadata = true }
            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }
            // Stop at mount points, like `du -x`: a mounted simulator runtime
            // or disk image is another volume and not part of this folder.
            if values.isVolume == true {
                enumerator.skipDescendants()
                continue
            }
            let isRegularFile = values.isRegularFile == true
            if isRegularFile {
                var counted = true
                if (values.linkCount ?? 1) > 1, let id = values.fileResourceIdentifier as? NSObject {
                    counted = seenLinked.insert(id).inserted
                }
                if counted {
                    stats.size += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
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
        stats.unreadableEntries = errors.count
        return stats
    }

    static func isVanished(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    /// True when any path component of `url` *below* the scan root is
    /// dot-prefixed, so files buried inside `.git` or `.cache` are skipped too.
    private static func isHidden(_ url: URL, belowComponentCount rootComponentCount: Int) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponentCount else { return false }
        return components[rootComponentCount...].contains { $0.hasPrefix(".") }
    }
}
