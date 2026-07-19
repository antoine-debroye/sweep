import XCTest
@testable import SweepCore

/// Exercises the incremental `DiskTreeScanner.stream` producer (and the `children`
/// collector built on it) against a real temp fixture — verifies nodes stream in,
/// folders are sized recursively, and the collector preserves largest-first order.
final class DiskTreeScannerStreamTests: XCTestCase {
    private var root: URL!
    private let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/testuser"))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A/ holds the biggest file, B/ a small one, plus a mid-size top-level file.
        try makeDir("A", file: "big.bin", bytes: 200_000)
        try makeDir("B", file: "small.bin", bytes: 4_000)
        try write(root.appendingPathComponent("c.bin"), bytes: 40_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDir(_ name: String, file: String, bytes: Int) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(dir.appendingPathComponent(file), bytes: bytes)
    }

    /// Patterned (non-zero, varying) bytes so APFS transparent compression can't
    /// collapse allocated size and skew the relative ordering.
    private func write(_ url: URL, bytes: Int) throws {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<bytes { p[i] = UInt8((i &* 31 &+ 7) & 0xFF) }
        }
        try data.write(to: url)
    }

    func testStreamYieldsAllDirectChildren() async {
        var byName: [String: DiskNode] = [:]
        for await node in DiskTreeScanner.stream(of: root, policy: policy) {
            byName[node.name] = node
        }
        XCTAssertEqual(Set(byName.keys), ["A", "B", "c.bin"])

        let a = try! XCTUnwrap(byName["A"])
        let b = try! XCTUnwrap(byName["B"])
        let c = try! XCTUnwrap(byName["c.bin"])

        XCTAssertTrue(a.isDirectory)
        XCTAssertFalse(c.isDirectory)
        XCTAssertEqual(a.fileCount, 1)                 // one file recursively counted
        XCTAssertGreaterThan(a.allocatedSize, b.allocatedSize)   // 200KB folder > 4KB folder
        XCTAssertGreaterThan(a.allocatedSize, c.allocatedSize)   // 200KB folder > 40KB file
    }

    func testChildrenCollectorIsSortedLargestFirst() async {
        let nodes = await DiskTreeScanner.children(of: root, policy: policy)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes.first?.name, "A")         // largest first
        // Non-increasing allocated sizes.
        for (lhs, rhs) in zip(nodes, nodes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lhs.allocatedSize, rhs.allocatedSize)
        }
    }

    func testEmptyDirectoryStreamsNothing() async {
        let empty = root.appendingPathComponent("empty")
        try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        var count = 0
        for await _ in DiskTreeScanner.stream(of: empty, policy: policy) { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
