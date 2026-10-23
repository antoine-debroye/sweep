import XCTest
@testable import SweepCore

/// Ideas taken from tw93/Mole V1.59–V1.62, checked against fixtures. The real
/// disk is never touched.
final class MoleV162AlignmentTests: XCTestCase {
    var root: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "sweep-mole162-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func mkdir(_ relative: String) throws {
        try fm.createDirectory(at: root.appending(path: relative), withIntermediateDirectories: true)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A project whose playwright-core needs these builds, linked from `.links`.
    private func linkProject(_ name: String, browsers: [(String, String)], cache: String = "pw") throws {
        let core = "projects/\(name)/node_modules/playwright-core"
        let list = browsers.map { #"{"name":"\#($0.0)","revision":"\#($0.1)"}"# }.joined(separator: ",")
        try write(#"{"comment":"","browsers":[\#(list)]}"#, to: "\(core)/browsers.json")
        try write(root.appending(path: core).path, to: "\(cache)/.links/\(name)")
    }

    private func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    // MARK: Playwright

    func testPlaywrightKeepsBuildsAProjectUsesAndNewestOfEach() throws {
        for build in ["chromium-1100", "chromium-1200", "chromium-1248",
                      "chromium_headless_shell-1200", "chromium_headless_shell-1248", "ffmpeg-1013"] {
            try mkdir("pw/\(build)")
        }
        // An older project still on 1200, a current one on 1248.
        try linkProject("old", browsers: [("chromium", "1200")])
        try linkProject("new", browsers: [("chromium", "1248"), ("chromium-headless-shell", "1248"), ("ffmpeg", "1013")])

        let unused = DynamicPaths.unusedPlaywrightBrowsers(root: root.appending(path: "pw"))
        XCTAssertEqual(names(unused), ["chromium-1100", "chromium_headless_shell-1200"])
    }

    func testPlaywrightIgnoresLinksToDeletedProjects() throws {
        for build in ["chromium-1200", "chromium-1248"] { try mkdir("pw/\(build)") }
        try write(root.appending(path: "projects/gone/node_modules/playwright-core").path, to: "pw/.links/gone")
        XCTAssertEqual(names(DynamicPaths.unusedPlaywrightBrowsers(root: root.appending(path: "pw"))), ["chromium-1200"])
    }

    func testPlaywrightOffersNothingWhenALiveProjectCantBeRead() throws {
        for build in ["chromium-1200", "chromium-1248"] { try mkdir("pw/\(build)") }
        try mkdir("projects/broken/node_modules/playwright-core")   // no browsers.json
        try write(root.appending(path: "projects/broken/node_modules/playwright-core").path, to: "pw/.links/broken")
        XCTAssertTrue(DynamicPaths.unusedPlaywrightBrowsers(root: root.appending(path: "pw")).isEmpty)
    }

    func testAppCachesNoLongerTakePlaywrightWhole() throws {
        let rules = RuleCatalog.rules(home: root, includeSystemDomain: false)
        let caches = try XCTUnwrap(rules.first { $0.id == "user-caches" })
        XCTAssertTrue(caches.excludeNames.contains("ms-playwright"))
        let playwright = try XCTUnwrap(rules.first { $0.id == "playwright-old-browsers" })
        XCTAssertEqual(playwright.tier, .review)
        XCTAssertFalse(RuleCatalog.autoTrimRules(home: root, minAgeDays: 30).contains { $0.id == "playwright-old-browsers" })
    }

    // MARK: Developer folders

    func testMacOSDeviceSupportIsPrunedLikeOtherPlatforms() throws {
        let base = "Library/Developer/Xcode/macOS DeviceSupport"
        for (index, version) in ["14.5", "15.6", "26.0"].enumerated() {
            try mkdir("\(base)/\(version)")
            let date = Date(timeIntervalSinceNow: Double(index - 3) * 86_400)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appending(path: "\(base)/\(version)").path)
        }
        XCTAssertEqual(names(DynamicPaths.staleDeviceSupport(home: root, keep: 2)), ["14.5"])
    }

    func testDartToolIsAProjectArtifact() {
        XCTAssertTrue(ProjectArtifactScanner.artifactNames.contains(".dart_tool"))
    }

    // MARK: Uninstall: personal data

    func testPersonalDataIsToldApartFromDisposableLeftovers() {
        let lib = root.appending(path: "Library")
        for path in ["Application Support/com.acme.app", "Application Support/Acme", "Preferences/com.acme.app.plist",
                     "Containers/com.acme.app", "Group Containers/ABCDE12345.com.acme.app",
                     "WebKit/com.acme.app", "HTTPStorages/com.acme.app", "Cookies/com.acme.app.binarycookies"] {
            XCTAssertTrue(LeftoverFinder.isPersonalData(lib.appending(path: path), home: root), path)
        }
        for path in ["Caches/com.acme.app", "Logs/Acme", "Saved Application State/com.acme.app.savedState",
                     "Application Support/CrashReporter/Acme", "LaunchAgents/com.acme.app.plist"] {
            XCTAssertFalse(LeftoverFinder.isPersonalData(lib.appending(path: path), home: root), path)
        }
        // Outside the Library entirely.
        XCTAssertFalse(LeftoverFinder.isPersonalData(root.appending(path: "Documents/Application Support/x"), home: root))
    }

    // MARK: Uninstall: Beta / Nightly builds

    private func app(_ name: String, _ id: String) -> (url: URL, name: String, bundleID: String) {
        (URL(fileURLWithPath: "/Applications/\(name).app"), name, id)
    }

    func testSiblingBuildsAreFoundByNameOrBundleID() {
        let installed = [
            app("Firefox", "org.mozilla.firefox"),
            app("Firefox Nightly", "org.mozilla.nightly"),
            app("Visual Studio Code", "com.microsoft.VSCode"),
            app("Visual Studio Code - Insiders", "com.microsoft.VSCodeInsiders"),
            app("Acme", "com.acme.app"),
            app("Acme Beta", "com.acme.app.beta"),
            app("Microsoft Edge", "com.microsoft.edgemac"),
            app("Notes Plus", "com.other.notes"),
        ]
        func siblings(of name: String) -> Set<String> {
            let me = installed.first { $0.name == name }!
            return Set(OtherAppCopies.siblingBuilds(bundleID: me.bundleID, appName: me.name, appURL: me.url, installed: installed)
                .map { $0.deletingPathExtension().lastPathComponent })
        }
        XCTAssertEqual(siblings(of: "Firefox"), ["Firefox Nightly"])
        XCTAssertEqual(siblings(of: "Firefox Nightly"), ["Firefox"])
        XCTAssertEqual(siblings(of: "Visual Studio Code"), ["Visual Studio Code - Insiders"])
        XCTAssertEqual(siblings(of: "Acme Beta"), ["Acme"])
        XCTAssertEqual(siblings(of: "Microsoft Edge"), [])
        XCTAssertEqual(siblings(of: "Notes Plus"), [])
    }

    func testSiblingBuildsHoldBackSelectionButNotBackgroundJobs() {
        let others = OtherAppCopies(siblings: [URL(fileURLWithPath: "/Applications/Firefox Nightly.app")])
        XCTAssertTrue(others.isEmpty, "a sibling has its own bundle id, so the app's own jobs may still be stopped")
        XCTAssertTrue(others.sharesData)
        XCTAssertNotNil(others.note(appName: "Firefox"))
    }

    // MARK: Protected data

    func testGameLibrariesAndClipboardHistoryAreNeverOfferedAsResidue() {
        for name in ["Steam", "Epic", "Unity", "UnityHub", "Raycast"] {
            XCTAssertTrue(BundleProtection.nameLooksDataSensitive(name), name)
        }
        for id in ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "com.unity3d.unityhub", "com.raycast.macos"] {
            XCTAssertTrue(BundleProtection.isDataSensitive(id), id)
        }
    }

    // MARK: Simulator tools

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func ready(selectStatus: Int32 = 0, developerDir: String = "/Applications/Xcode.app/Contents/Developer",
                       hasSimctl: Bool = true, firstLaunchStatus: Int32 = 0, calls: Calls = Calls()) async -> Bool {
        await SimulatorScanner.toolsReady(
            run: { path, args, _ in
                calls.add(([path] + args).joined(separator: " "))
                if path == "/usr/bin/xcode-select" { return ProcessResult(status: selectStatus, stdout: developerDir, stderr: "") }
                return ProcessResult(status: firstLaunchStatus, stdout: "", stderr: "")
            },
            fileExists: { path in path.hasSuffix("/xcodebuild") || (hasSimctl && path.hasSuffix("/simctl")) }
        )
    }

    func testSimulatorToolsNeedAFinishedXcode() async {
        let ok = await ready()
        XCTAssertTrue(ok)
        let noTools = await ready(selectStatus: 2, developerDir: "")
        XCTAssertFalse(noTools, "no developer tools: the xcrun shim would open the installer")
        let cltOnly = await ready(developerDir: "/Library/Developer/CommandLineTools", hasSimctl: false)
        XCTAssertFalse(cltOnly, "Command Line Tools have no simctl")
        let firstLaunchPending = await ready(firstLaunchStatus: 69)
        XCTAssertFalse(firstLaunchPending, "Xcode setup unfinished: simctl would ask for an admin password")
        let timedOut = await ready(firstLaunchStatus: ProcessRunner.timedOutStatus)
        XCTAssertFalse(timedOut)
    }

    func testSimulatorCheckNeverGoesThroughTheXcrunShim() async {
        let calls = Calls()
        _ = await ready(calls: calls)
        XCTAssertFalse(calls.all.contains { $0.hasPrefix("/usr/bin/xcrun") })
        XCTAssertTrue(calls.all.contains { $0.hasPrefix("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -checkFirstLaunchStatus") })
    }
}
