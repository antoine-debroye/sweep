import Foundation

/// JSON-backed store of every clean session, used for the History screen,
/// the lifetime-freed counter, and Trash-restore undo.
public actor HistoryStore {
    public static let shared = HistoryStore()

    private let fileURL: URL
    private var cached: [CleanSession]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Sweep")
            self.fileURL = dir.appending(path: "history.json")
        }
    }

    public func sessions() -> [CleanSession] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let sessions = try? JSONDecoder().decode([CleanSession].self, from: data) else {
            cached = []
            return []
        }
        cached = sessions.sorted { $0.date > $1.date }
        return cached!
    }

    public func add(_ session: CleanSession) {
        guard !session.items.isEmpty || !session.errors.isEmpty else { return }
        var all = sessions()
        all.insert(session, at: 0)
        if all.count > 200 { all = Array(all.prefix(200)) }
        cached = all
        persist()
    }

    public func lifetimeFreed() -> Int64 {
        sessions().filter { !$0.undone }.reduce(0) { $0 + $1.totalFreed }
    }

    public func lastCleanDate() -> Date? {
        sessions().first?.date
    }

    /// What Sweep moved to the Trash that is still sitting there: Trash-first
    /// cleaning does not free space until the Trash is emptied.
    public struct TrashHeld: Sendable, Equatable {
        public var count = 0
        public var bytes: Int64 = 0
        public var oldest: Date?
        public init(count: Int = 0, bytes: Int64 = 0, oldest: Date? = nil) {
            self.count = count
            self.bytes = bytes
            self.oldest = oldest
        }
    }

    public func trashHeld() -> TrashHeld {
        let fm = FileManager()
        var held = TrashHeld()
        // Finder reuses Trash names once the Trash has been emptied, so an old
        // session's trashPath can point at a NEWER session's file. Count each
        // path once, attributed to the most recent session (sessions are
        // newest-first) — otherwise stale records inflate the total.
        var seen = Set<String>()
        for session in sessions().sorted(by: { $0.date > $1.date }) where !session.undone {
            for item in session.items {
                guard let path = item.trashPath, seen.insert(path).inserted, fm.fileExists(atPath: path) else { continue }
                held.count += 1
                held.bytes += item.size
                if held.oldest == nil || session.date < held.oldest! { held.oldest = session.date }
            }
        }
        return held
    }

    /// Permanently removes ONLY the items Sweep itself put in the Trash (never
    /// the user's other trashed files) and marks them non-restorable.
    public func purgeTrashedItems() -> (removed: Int, bytes: Int64, errors: Int) {
        let fm = FileManager()
        // Newest first so a reused Trash path is removed (and its size
        // reported) under the record that actually owns the file today.
        var all = sessions().sorted { $0.date > $1.date }
        var removed = 0
        var bytes: Int64 = 0
        var errors = 0
        for s in all.indices where !all[s].undone {
            for i in all[s].items.indices {
                guard let path = all[s].items[i].trashPath else { continue }
                guard Cleaner.isInTrash(URL(fileURLWithPath: path)) else { continue }
                if !fm.fileExists(atPath: path) {
                    all[s].items[i].trashPath = nil
                    continue
                }
                do {
                    try fm.removeItem(atPath: path)
                    all[s].items[i].trashPath = nil
                    removed += 1
                    bytes += all[s].items[i].size
                } catch {
                    errors += 1
                }
            }
        }
        cached = all
        persist()
        return (removed, bytes, errors)
    }

    /// Restores every item of the session that still exists in the Trash.
    /// Returns (restored, missing) counts.
    public func undo(sessionID: UUID) -> (restored: Int, missing: Int) {
        var all = sessions()
        guard let index = all.firstIndex(where: { $0.id == sessionID }) else { return (0, 0) }
        var session = all[index]
        let fm = FileManager()
        var restored = 0
        var missing = 0

        for i in session.items.indices {
            guard let trashPath = session.items[i].trashPath else { continue }
            guard fm.fileExists(atPath: trashPath) else {
                missing += 1
                continue
            }
            let destination = session.items[i].originalPath
            let destinationDir = (destination as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination) {
                    missing += 1
                    continue
                }
                try fm.moveItem(atPath: trashPath, toPath: destination)
                session.items[i].trashPath = nil
                restored += 1
            } catch {
                missing += 1
            }
        }

        session.undone = restored > 0
        all[index] = session
        cached = all
        persist()
        return (restored, missing)
    }

    public func clear() {
        cached = []
        persist()
    }

    private func persist() {
        guard let sessions = cached else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.sweep.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Sweep: failed to persist history: \(error)")
        }
    }
}

extension JSONEncoder {
    static var sweep: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
