import XCTest
@testable import SweepCore

/// Pure LRU + TTL behaviour of the Disk Explorer level cache. No filesystem.
final class DiskLevelCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func node(_ path: String, size: Int64 = 1) -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: true,
            allocatedSize: size, logicalSize: size,
            fileCount: 1, newestModification: nil,
            kind: .review
        )
    }

    private func level(_ path: String) -> [DiskNode] { [node(path + "/child")] }

    // MARK: Store / lookup

    func testStoreThenLookupReturnsNodes() {
        var cache = DiskLevelCache()
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        let hit = cache.lookup(path: "/a", now: t0)
        XCTAssertEqual(hit?.count, 1)
        XCTAssertEqual(hit?.first?.url.path, "/a/child")
    }

    func testLookupMissReturnsNil() {
        var cache = DiskLevelCache()
        XCTAssertNil(cache.lookup(path: "/nope", now: t0))
    }

    // MARK: TTL

    func testLookupWithinTTLReturnsNodes() {
        var cache = DiskLevelCache(ttl: 100)
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        XCTAssertNotNil(cache.lookup(path: "/a", now: t0.addingTimeInterval(50)))
    }

    func testLookupPastTTLReturnsNil() {
        var cache = DiskLevelCache(ttl: 100)
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        XCTAssertNil(cache.lookup(path: "/a", now: t0.addingTimeInterval(150)))
        // Expired entry is dropped, so a later in-window lookup still misses.
        XCTAssertNil(cache.lookup(path: "/a", now: t0.addingTimeInterval(151)))
    }

    // MARK: Invalidation

    func testInvalidatePathDropsOneLevel() {
        var cache = DiskLevelCache()
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        cache.store(path: "/b", nodes: level("/b"), now: t0)
        cache.invalidate(path: "/a")
        XCTAssertNil(cache.lookup(path: "/a", now: t0))
        XCTAssertNotNil(cache.lookup(path: "/b", now: t0))
    }

    func testInvalidatePrefixDropsSubtreeButKeepsSibling() {
        var cache = DiskLevelCache()
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        cache.store(path: "/a/b", nodes: level("/a/b"), now: t0)
        cache.store(path: "/a/b/c", nodes: level("/a/b/c"), now: t0)
        cache.store(path: "/ab", nodes: level("/ab"), now: t0)   // prefix-string sibling, not a subtree

        cache.invalidate(pathsWithPrefix: "/a/b")

        XCTAssertNil(cache.lookup(path: "/a/b", now: t0))
        XCTAssertNil(cache.lookup(path: "/a/b/c", now: t0))
        XCTAssertNotNil(cache.lookup(path: "/a", now: t0))       // ancestor kept
        XCTAssertNotNil(cache.lookup(path: "/ab", now: t0))      // "/ab" is not under "/a/b"
    }

    // MARK: LRU capacity

    func testCapacityEvictsLeastRecentlyUsed() {
        var cache = DiskLevelCache(capacity: 2)
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        cache.store(path: "/b", nodes: level("/b"), now: t0)
        cache.store(path: "/c", nodes: level("/c"), now: t0)     // evicts /a
        XCTAssertNil(cache.lookup(path: "/a", now: t0))
        XCTAssertNotNil(cache.lookup(path: "/b", now: t0))
        XCTAssertNotNil(cache.lookup(path: "/c", now: t0))
    }

    func testLookupHitRefreshesRecency() {
        var cache = DiskLevelCache(capacity: 2)
        cache.store(path: "/a", nodes: level("/a"), now: t0)
        cache.store(path: "/b", nodes: level("/b"), now: t0)
        _ = cache.lookup(path: "/a", now: t0)                    // /a now most-recent
        cache.store(path: "/c", nodes: level("/c"), now: t0)     // evicts /b, not /a
        XCTAssertNotNil(cache.lookup(path: "/a", now: t0))
        XCTAssertNil(cache.lookup(path: "/b", now: t0))
        XCTAssertNotNil(cache.lookup(path: "/c", now: t0))
    }
}
