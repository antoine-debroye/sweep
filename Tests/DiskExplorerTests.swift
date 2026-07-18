import XCTest
@testable import SweepCore

/// The Disk Explorer's safety/cloud classification and the Large Files date
/// plausibility logic — both pure, so testable without touching real files.
final class DiskExplorerTests: XCTestCase {
    private let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/testuser"))
    private let gb: Int64 = 1_000_000_000

    private func classify(_ path: String, allocated: Int64, logical: Int64, ubiquitous: Bool = false) -> DiskNodeKind {
        DiskTreeScanner.classify(
            url: URL(fileURLWithPath: path),
            allocated: allocated, logical: logical,
            isUbiquitous: ubiquitous, policy: policy
        )
    }

    // MARK: Safety classification

    func testUserDataIsProtected() {
        XCTAssertEqual(classify("/Users/testuser/Documents/tax.pdf", allocated: gb, logical: gb), .protectedPath)
        XCTAssertEqual(classify("/Users/testuser/Desktop/big.mov", allocated: gb, logical: gb), .protectedPath)
    }

    func testCachesFolderProtectedButContentsSafe() {
        // The Caches folder itself must not be deleted…
        XCTAssertEqual(classify("/Users/testuser/Library/Caches", allocated: gb, logical: gb), .protectedPath)
        // …but its contents are regenerable.
        XCTAssertEqual(classify("/Users/testuser/Library/Caches/com.foo.bar", allocated: gb, logical: gb), .safeToDelete)
    }

    func testRegenerableIsSafe() {
        XCTAssertEqual(classify("/Users/testuser/Projects/app/node_modules", allocated: 500_000_000, logical: 500_000_000), .safeToDelete)
        XCTAssertEqual(classify("/Users/testuser/Library/Developer/Xcode/DerivedData/App-abc", allocated: gb, logical: gb), .safeToDelete)
    }

    func testUserFilesAreReview() {
        XCTAssertEqual(classify("/Users/testuser/Projects/app/dataset.bin", allocated: 2 * gb, logical: 2 * gb), .review)
    }

    // MARK: Cloud detection (allocated-vs-logical delta)

    func testMaterializedCloudFileIsOffloadable() {
        let kind = classify("/Users/testuser/Library/CloudStorage/OneDrive-Personal/movie.mov", allocated: 2 * gb, logical: 2 * gb)
        XCTAssertEqual(kind, .cloudOffloadable(localBytes: 2 * gb))
        XCTAssertFalse(kind.isDeletable)        // cloud items never deletable
        XCTAssertTrue(kind.isCloud)
        XCTAssertEqual(kind.offloadableBytes, 2 * gb)
    }

    func testOnlineOnlyCloudFileHasNothingToReclaim() {
        // Large logical, ~zero allocated = a dataless placeholder already offloaded.
        let kind = classify("/Users/testuser/Library/CloudStorage/OneDrive-Personal/archive.zip", allocated: 4096, logical: 5 * gb)
        XCTAssertEqual(kind, .cloudOnlineOnly)
        XCTAssertEqual(kind.offloadableBytes, 0)
    }

    func testUbiquitousItemDetectedEvenOutsideCloudStorage() {
        let kind = classify("/Users/testuser/somewhere/icloudy.pages", allocated: gb, logical: gb, ubiquitous: true)
        XCTAssertEqual(kind, .cloudOffloadable(localBytes: gb))
    }

    func testCloudTakesPrecedenceAndIsNeverDeletable() {
        // CloudStorage is also a protected subtree; cloud classification wins,
        // and either way the item is not deletable.
        let kind = classify("/Users/testuser/Library/CloudStorage/Dropbox/big.psd", allocated: 3 * gb, logical: 3 * gb)
        XCTAssertTrue(kind.isCloud)
        XCTAssertFalse(kind.isDeletable)
    }

    // MARK: LargeFile.displayDate

    func testDisplayDatePrefersPlausibleModified() {
        let d = Date(timeIntervalSince1970: 1_700_000_000) // 2023
        let f = LargeFile(url: URL(fileURLWithPath: "/tmp/a"), size: 1, modified: d, created: nil, lastAccessed: nil)
        XCTAssertEqual(f.displayDate, d)
    }

    func testDisplayDateFallsBackToCreationWhenModifiedIsEpoch() {
        let epoch = Date(timeIntervalSince1970: 0)          // the "46 yr ago" case
        let created = Date(timeIntervalSince1970: 1_600_000_000) // 2020
        let f = LargeFile(url: URL(fileURLWithPath: "/tmp/a"), size: 1, modified: epoch, created: created, lastAccessed: nil)
        XCTAssertEqual(f.displayDate, created)
    }

    func testDisplayDateNilWhenAllDatesImplausible() {
        let epoch = Date(timeIntervalSince1970: 0)
        let f = LargeFile(url: URL(fileURLWithPath: "/tmp/a"), size: 1, modified: epoch, created: epoch, lastAccessed: nil)
        XCTAssertNil(f.displayDate)

        let g = LargeFile(url: URL(fileURLWithPath: "/tmp/b"), size: 1, modified: nil, created: nil, lastAccessed: nil)
        XCTAssertNil(g.displayDate)
    }
}
