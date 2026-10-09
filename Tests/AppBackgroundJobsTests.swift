import XCTest
@testable import SweepCore

final class AppBackgroundJobsTests: XCTestCase {
    var root: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "sweep-jobs-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func plist(_ dict: [String: Any], at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    func testOwnedLabelsComeFromTheBundleAndTheAgentsBeingRemoved() throws {
        let app = root.appending(path: "Acme.app")
        try plist(["CFBundleIdentifier": "com.acme.app.LoginHelper", "CFBundlePackageType": "APPL"],
                  at: app.appending(path: "Contents/Library/LoginItems/Acme Helper.app/Contents/Info.plist"))
        try plist(["Label": "com.acme.app.agent"], at: app.appending(path: "Contents/Library/LaunchAgents/com.acme.app.agent.plist"))
        let removed = root.appending(path: "LaunchAgents/com.acme.app.plist")
        try plist(["Label": "com.acme.app.updater"], at: removed)
        let apple = root.appending(path: "LaunchAgents/com.apple.something.plist")
        try plist(["Label": "com.apple.something"], at: apple)

        let labels = AppBackgroundJobs.ownedLabels(appURL: app, removingAgentPlists: [removed, apple])
        XCTAssertEqual(labels, ["com.acme.app.LoginHelper", "com.acme.app.agent", "com.acme.app.updater"])
    }

    func testProcessesInsideMatchTheBundleOnly() {
        let app = URL(fileURLWithPath: "/Applications/Acme.app")
        let running: Set<String> = [
            "/Applications/Acme.app/Contents/Library/LoginItems/Acme Helper.app/Contents/MacOS/Acme Helper",
            "/Applications/Acme.app2/Contents/MacOS/Other",
            "/usr/bin/true",
        ]
        XCTAssertEqual(AppBackgroundJobs.processesInside(app, running: running).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["Acme Helper"])
    }

    func testOnlyLoadedJobsAreBootedOut() async {
        let calls = CallLog()
        let launchctl: AppBackgroundJobs.Launchctl = { args in
            calls.append(args.joined(separator: " "))
            switch (args[0], args[1]) {
            case ("print", "gui/501/com.acme.loaded"), ("print", "gui/501/com.acme.stuck"):
                return ProcessResult(status: 0, stdout: "", stderr: "")
            case ("print", _):
                return ProcessResult(status: 113, stdout: "", stderr: "Could not find service")
            case ("bootout", "gui/501/com.acme.stuck"):
                return ProcessResult(status: ProcessRunner.timedOutStatus, stdout: "", stderr: "")
            default:
                return ProcessResult(status: 0, stdout: "", stderr: "")
            }
        }
        let result = await AppBackgroundJobs.stop(
            labels: ["com.acme.loaded", "com.acme.absent", "com.acme.stuck"], uid: 501, launchctl: launchctl)
        XCTAssertEqual(result.stopped, ["com.acme.loaded"])
        XCTAssertEqual(result.failed, ["com.acme.stuck"])
        XCTAssertFalse(calls.entries.contains("bootout gui/501/com.acme.absent"))
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ entry: String) { lock.lock(); storage.append(entry); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
