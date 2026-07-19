import Foundation

/// A small LRU + TTL cache of already-measured directory levels, keyed by absolute
/// path. Lets Disk Explorer serve breadcrumb-back and re-drill navigation instantly
/// instead of re-walking subtrees that were just measured.
///
/// It is a pure value type mutated only on the `@MainActor` model — no locking, no
/// shared mutable state, and (unlike an actor) no cross-actor hop that could
/// reintroduce an off-main isolation bug. `now` is injected so the TTL is
/// deterministically unit-testable.
public struct DiskLevelCache: Sendable {
    private struct Entry: Sendable {
        let nodes: [DiskNode]
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []   // LRU recency: least-recent first, most-recent last

    public let ttl: TimeInterval
    public let capacity: Int

    public init(ttl: TimeInterval = 300, capacity: Int = 64) {
        self.ttl = ttl
        self.capacity = capacity
    }

    /// The cached level for `path` if present and not past `ttl`; refreshes its LRU
    /// recency on a hit. Expired entries are dropped as a side effect.
    public mutating func lookup(path: String, now: Date) -> [DiskNode]? {
        guard let entry = entries[path] else { return nil }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            remove(path)
            return nil
        }
        touch(path)
        return entry.nodes
    }

    /// Stores (or replaces) the level for `path`, evicting the least-recently-used
    /// entries once `capacity` is exceeded.
    public mutating func store(path: String, nodes: [DiskNode], now: Date) {
        entries[path] = Entry(nodes: nodes, storedAt: now)
        touch(path)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries[evicted] = nil
        }
    }

    /// Drops the cached level for exactly `path`.
    public mutating func invalidate(path: String) { remove(path) }

    /// Drops `path` and every cached level beneath it (its whole subtree).
    public mutating func invalidate(pathsWithPrefix prefix: String) {
        let subtree = prefix + "/"
        for key in entries.keys where key == prefix || key.hasPrefix(subtree) {
            remove(key)
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    // MARK: - LRU bookkeeping

    private mutating func touch(_ path: String) {
        if let idx = order.firstIndex(of: path) { order.remove(at: idx) }
        order.append(path)
    }

    private mutating func remove(_ path: String) {
        entries[path] = nil
        if let idx = order.firstIndex(of: path) { order.remove(at: idx) }
    }
}
