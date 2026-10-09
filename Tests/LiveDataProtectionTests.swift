import XCTest
@testable import SweepCore

/// Live state that sits inside cache-shaped folders, folders macOS can't
/// recreate, and the measurement fixes that keep totals honest.
final class LiveDataProtectionTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-live-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 200_000, ageDays: Int = 30) throws -> URL {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        var item = url
        while item.path.count > home.path.count {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
            item = item.deletingLastPathComponent()
        }
        return url
    }

    private func offeredPaths(running: Set<String> = []) async -> Set<String> {
        let engine = ScanEngine(policy: SafetyPolicy(home: home), runningBundleIDs: running)
        let items = await engine.scanReport(rules: RuleCatalog.rules(home: home, includeSystemDomain: false)).items
        let base = home.path + "/"
        return Set(items.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") })
    }

    // MARK: - Live data inside caches

    func testLiveDataAndEveryFolderAboveItAreProtected() {
        let policy = SafetyPolicy(home: home)
        let caches = home.appending(path: "Library/Caches")
        for protected in [
            "org.R-project.R", "org.R-project.R/R", "org.R-project.R/R/renv", "org.R-project.R/R/renv/library/x",
            "pypoetry", "pypoetry/virtualenvs/app-py3.12",
            "GIPPseudonymousID", "CCTClearcutLogger/queue",
            "deno", "deno/location_data",
        ] {
            XCTAssertTrue(policy.isProtected(caches.appending(path: protected)), protected)
        }
        // Siblings of the live data stay cleanable.
        for allowed in ["pypoetry/artifacts", "pypoetry/cache", "deno/remote", "deno/npm", "org.R-project.R2"] {
            XCTAssertFalse(policy.isProtected(caches.appending(path: allowed)), allowed)
        }
    }

    func testCacheSweepNoLongerOffersFoldersHoldingLiveData() async throws {
        try file("Library/Caches/org.R-project.R/R/renv/library/dplyr/DESCRIPTION")
        try file("Library/Caches/pypoetry/virtualenvs/app-py3.12/bin/python")
        try file("Library/Caches/pypoetry/artifacts/ab/cd/pkg.whl")
        try file("Library/Caches/GIPPseudonymousID/id")
        try file("Library/Caches/deno/location_data/abc/local_storage")
        try file("Library/Caches/deno/remote/https/deno.land/x.js")
        try file("Library/Caches/com.vendor.app/cache.db")

        let offered = await offeredPaths()
        XCTAssertTrue(offered.contains("Library/Caches/com.vendor.app"), "\(offered)")
        XCTAssertTrue(offered.contains("Library/Caches/pypoetry/artifacts"))
        XCTAssertTrue(offered.contains("Library/Caches/deno/remote"))
        for kept in ["Library/Caches/org.R-project.R", "Library/Caches/pypoetry", "Library/Caches/GIPPseudonymousID",
                     "Library/Caches/deno"] {
            XCTAssertFalse(offered.contains(kept), "\(kept) holds live data")
        }
        XCTAssertFalse(offered.contains { $0.contains("virtualenvs") || $0.contains("location_data") })
    }

    // MARK: - DiagnosticReports

    /// The crash reporter can't recreate the folder from its sandbox. The
    /// reports go; the folder stays.
    func testCrashReportsAreCleanedButTheirFolderIsKept() async throws {
        try file("Library/Logs/DiagnosticReports/Foo_2026-09-01.ips")
        try file("Library/Logs/com.vendor.app/old.log")
        try file("Library/DiagnosticReports/Bar_2026-09-02.ips")

        let offered = await offeredPaths()
        XCTAssertTrue(offered.contains("Library/Logs/DiagnosticReports/Foo_2026-09-01.ips"), "\(offered)")
        XCTAssertTrue(offered.contains("Library/DiagnosticReports/Bar_2026-09-02.ips"))
        XCTAssertTrue(offered.contains("Library/Logs/com.vendor.app"))
        XCTAssertFalse(offered.contains("Library/Logs/DiagnosticReports"))
        XCTAssertTrue(SafetyPolicy(home: home).isProtected(home.appending(path: "Library/Logs/DiagnosticReports")))
    }

    /// A cleanable folder that is really a symlink into a protected one must
    /// not lend its harmless-looking path to the files behind it.
    func testSymlinkedFolderCannotRedirectCleaningIntoProtectedData() async throws {
        try file("Documents/reports/keep-me.ips")
        try fm.createDirectory(at: home.appending(path: "Library/Logs"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "Library/Logs/DiagnosticReports"),
                                  withDestinationURL: home.appending(path: "Documents/reports"))

        let offered = await offeredPaths()
        XCTAssertFalse(offered.contains { $0.contains("keep-me") }, "\(offered)")

        let lexical = home.appending(path: "Library/Logs/DiagnosticReports/keep-me.ips")
        let item = ScanItem(ruleID: "crash-reports", category: .systemJunk, url: lexical, displayName: "keep-me.ips",
                            detail: "", size: 1, fileCount: 1, newestModification: nil, tier: .safe, domain: .user)
        let recorder = RecordingRemover()
        let cleaner = Cleaner(policy: SafetyPolicy(home: home), trashRemover: recorder, permanentRemover: recorder)
        let session = await cleaner.clean(items: [item], source: .smartScan, permanentDelete: false)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(session.errors.contains { $0.hasPrefix("Refused protected path") })
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "Documents/reports/keep-me.ips").path))
    }

    /// Removing a symlink moves the link, never its target — so a link item
    /// itself is still fine to offer.
    func testASymlinkItemIsNotTreatedAsItsTarget() throws {
        try file("Documents/notes.txt")
        let link = home.appending(path: "Library/Caches/notes-link")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Documents/notes.txt"))
        XCTAssertFalse(SafetyPolicy(home: home).isProtectedOrRedirected(link))
    }

    // MARK: - Editor caches

    func testVSCodeExtensionDownloadCacheIsOffered() async throws {
        try file("Library/Application Support/Code/CachedExtensionVSIXs/ms-python.python-2026.1.0")
        try file("Library/Application Support/Code/User/settings.json")
        let offered = await offeredPaths()
        XCTAssertTrue(offered.contains("Library/Application Support/Code/CachedExtensionVSIXs"))
        XCTAssertFalse(offered.contains { $0.contains("Code/User") })
    }

    func testObsoleteExtensionsRequireAnExplicitTrue() throws {
        let root = home.appending(path: ".vscode/extensions")
        for name in ["old.ext-1.0.0", "kept.ext-2.0.0", "weird.ext-3.0.0"] {
            try fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        let journal = #"{"old.ext-1.0.0": true, "kept.ext-2.0.0": false, "weird.ext-3.0.0": {"nested": true}}"#
        try journal.write(to: root.appending(path: ".obsolete"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DynamicPaths.obsoleteExtensionDirs(extensionsRoot: root).map(\.lastPathComponent), ["old.ext-1.0.0"])
    }

    // MARK: - Browser channels

    func testEachBrowserChannelProtectsItsOwnCaches() {
        let support = "/Users/x/Library/Application Support/"
        let canary = URL(fileURLWithPath: support + "Google/Chrome Canary/Default/Code Cache")
        let nightly = URL(fileURLWithPath: support + "BraveSoftware/Brave-Browser-Nightly/Default/GPUCache")
        // A channel running on its own used to look like "Chrome isn't running".
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(canary, running: ["com.google.Chrome.canary"]))
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(nightly, running: ["com.brave.Browser.nightly"]))
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(canary, running: ["com.vendor.other"]))
        // The vendor folder above every channel belongs to whichever runs.
        let vendor = URL(fileURLWithPath: "/Users/x/Library/Caches/Google")
        XCTAssertTrue(RunningAppGuard.isOwnedByRunningApp(vendor, running: ["com.google.Chrome.beta"]))
        XCTAssertFalse(RunningAppGuard.isOwnedByRunningApp(vendor, running: ["com.google.drivefs"]))
    }

    // MARK: - Overlapping rules

    func testNestedItemsCountOnce() {
        func item(_ path: String) -> ScanItem {
            ScanItem(ruleID: "r", category: .systemJunk, url: URL(fileURLWithPath: path), displayName: path,
                     detail: "", size: 100, fileCount: 1, newestModification: nil, tier: .safe, domain: .user)
        }
        let items = [
            item("/U/x/Library/Caches/Google/Chrome"),
            item("/U/x/Library/Caches/Google"),
            item("/U/x/Library/Caches/GoogleUpdater"),   // a sibling with a shared prefix, not a child
        ]
        let kept = ScanItem.collapsingNested(items).map(\.url.path)
        XCTAssertEqual(Set(kept), ["/U/x/Library/Caches/Google", "/U/x/Library/Caches/GoogleUpdater"])
    }

    // MARK: - Measurement

    func testHardLinkedFilesAreCountedOnce() throws {
        let original = try file("tree/a/blob.bin", bytes: 1_000_000)
        try fm.createDirectory(at: home.appending(path: "tree/b"), withIntermediateDirectories: true)
        try fm.linkItem(at: original, to: home.appending(path: "tree/b/blob-link.bin"))
        let stats = DirectorySizer.stats(of: home.appending(path: "tree"))
        XCTAssertEqual(stats.fileCount, 2)
        XCTAssertLessThan(stats.size, 1_500_000, "a hard link is the same blocks, not a second megabyte")
        XCTAssertGreaterThanOrEqual(stats.size, 1_000_000)
    }

    func testUnreadableSubfolderMarksTheSizePartial() throws {
        try file("tree/open/a.bin")
        try file("tree/locked/b.bin")
        let locked = home.appending(path: "tree/locked")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertTrue(DirectorySizer.stats(of: home.appending(path: "tree")).isPartial)
        XCTAssertFalse(DirectorySizer.stats(of: home.appending(path: "tree/open")).isPartial)
    }

    func testRepositoryAnywhereInsideIsNoticed() throws {
        try file("build/ios/Pods/Thing/.git/HEAD")
        try file("dist/bundle.js")
        XCTAssertTrue(DirectorySizer.stats(of: home.appending(path: "build")).containsGitMetadata)
        XCTAssertFalse(DirectorySizer.stats(of: home.appending(path: "dist")).containsGitMetadata)
    }

    // MARK: - Zipped installers

    private func zip(_ name: String, containing entries: [String]) throws -> URL {
        let staging = home.appending(path: "staging-\(name)")
        for entry in entries {
            let url = staging.appending(path: entry)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Incompressible bytes so the archive clears the 1 MB floor.
            var bytes = [UInt8](repeating: 0, count: 600_000)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
            try Data(bytes).write(to: url)
        }
        let archive = home.appending(path: "Downloads/\(name)")
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = ProcessRunner.runBlocking("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, archive.path], timeout: 30)
        XCTAssertEqual(result.status, 0, result.stderr)
        return archive
    }

    func testZipsHoldingAnAppAreRecognisedAsInstallers() throws {
        let app = try zip("Tool.zip", containing: ["Tool.app/Contents/MacOS/Tool", "Tool.app/Contents/Info.plist"])
        let pkg = try zip("Driver.zip", containing: ["Driver Installer.pkg", "README.txt"])
        let photos = try zip("Holiday.zip", containing: ["IMG_0001.jpg", "IMG_0002.jpg"])

        XCTAssertTrue(ZipListing.entryNames(of: app)?.contains { $0.contains("Tool.app/") } ?? false)
        let found = Set(DynamicPaths.installerArchives(in: home.appending(path: "Downloads")).map(\.lastPathComponent))
        XCTAssertEqual(found, [app.lastPathComponent, pkg.lastPathComponent])
        XCTAssertFalse(found.contains(photos.lastPathComponent))
    }

    func testNotAZipIsNotAnInstaller() throws {
        let fake = try file("Downloads/fake.zip", bytes: 2_000_000)
        XCTAssertNil(ZipListing.entryNames(of: fake))
        XCTAssertTrue(DynamicPaths.installerArchives(in: home.appending(path: "Downloads")).isEmpty)
    }
}
