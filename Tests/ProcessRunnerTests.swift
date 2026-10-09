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

    func testMissingExecutableIs127() {
        let result = ProcessRunner.runBlocking("/nonexistent/tool", [], timeout: nil)
        XCTAssertEqual(result.status, 127)
    }
}
