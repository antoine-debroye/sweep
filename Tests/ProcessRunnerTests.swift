import XCTest
@testable import SweepCore

final class ProcessRunnerTests: XCTestCase {

    /// The limit must bound the wall clock. The old implementation raced a
    /// timer inside a task group, and a group waits for all of its children —
    /// so a 5 s child still took 5 s and was then mislabelled as timed out.
    func testTimeoutKillsTheChildAndReturnsPromptly() async {
        let start = Date()
        let result = await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.status, ProcessRunner.timedOutStatus)
        XCTAssertLessThan(elapsed, 2.5, "timeout did not bound the call (took \(elapsed)s)")
    }

    func testFastChildIsNotReportedAsTimedOut() async {
        let result = await ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello")
    }

    func testSignalDeathReadsAsShellStyleStatus() {
        let result = ProcessRunner.runBlocking("/bin/sh", ["-c", "kill -TERM $$"], timeout: 5)
        XCTAssertEqual(result.status, 128 + SIGTERM)
    }

    /// Dozens of concurrent runs (one `git status` per worktree) once parked
    /// every thread of GCD's shared pool while the pipe readers they waited
    /// on queued for a thread that never came. After 30 s the wait gave up
    /// and returned status 0 with empty output — "clean" for a dirty worktree.
    func testManyConcurrentRunsAllReturnTheirOutput() async {
        let start = Date()
        let results = await withTaskGroup(of: (Int, ProcessResult).self) { group in
            for i in 0..<100 {
                group.addTask { (i, await ProcessRunner.run("/bin/echo", ["run-\(i)"], timeout: 15)) }
            }
            var all: [(Int, ProcessResult)] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.count, 100)
        for (i, result) in results {
            XCTAssertEqual(result.status, 0, "run \(i): \(result.stderr)")
            XCTAssertEqual(result.stdout, "run-\(i)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testMissingExecutableIs127() {
        let result = ProcessRunner.runBlocking("/nonexistent/tool", [], timeout: nil)
        XCTAssertEqual(result.status, 127)
    }
}

/// An unsigned build must never manage the system-wide helper registration.
@MainActor
final class PrivilegeBrokerSigningTests: XCTestCase {
    func testUnsignedProcessIsNotTrustedToManageTheHelper() {
        // The test runner is not signed with Sweep's Developer ID team. (No
        // install/uninstall call here: if this guard ever regressed, the test
        // itself would change the machine's real helper registration.)
        XCTAssertFalse(PrivilegeBroker.isSignedForHelper)
    }
}
