import XCTest
@testable import SweepCore

/// Honest disk reporting: `available` excludes purgeable, `opportunisticAvailable`
/// adds it back (the figure the low-disk trigger compares against).
final class DiskSnapshotTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    func testUsedAndFractionUseHonestAvailable() {
        let snap = DiskSnapshot(total: 100 * gb, available: 25 * gb, purgeable: 30 * gb)
        // Used counts purgeable as occupied — it isn't honestly free.
        XCTAssertEqual(snap.used, 75 * gb)
        XCTAssertEqual(snap.usedFraction, 0.75, accuracy: 0.0001)
    }

    func testOpportunisticAvailableAddsPurgeable() {
        let snap = DiskSnapshot(total: 100 * gb, available: 25 * gb, purgeable: 30 * gb)
        XCTAssertEqual(snap.opportunisticAvailable, 55 * gb)
    }

    func testPurgeableDefaultsToZero() {
        let snap = DiskSnapshot(total: 100 * gb, available: 40 * gb)
        XCTAssertEqual(snap.purgeable, 0)
        XCTAssertEqual(snap.opportunisticAvailable, snap.available)
    }

    func testUsedNeverNegative() {
        // Defensive: available reported larger than total must not yield negative used.
        let snap = DiskSnapshot(total: 10 * gb, available: 12 * gb)
        XCTAssertEqual(snap.used, 0)
        XCTAssertEqual(snap.usedFraction, 0)
    }

    func testZeroTotalYieldsZeroFraction() {
        let snap = DiskSnapshot(total: 0, available: 0)
        XCTAssertEqual(snap.usedFraction, 0)
    }
}
