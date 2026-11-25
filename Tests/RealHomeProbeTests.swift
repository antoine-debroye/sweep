import XCTest
import AppKit
@testable import SweepCore

/// A read-only probe against the *real* home, used to validate leftover
/// detection against a machine with ~95 name-style folders in Application
/// Support. Skipped unless `SWEEP_REAL_HOME_PROBE=1`, because it depends on
/// whatever is installed on the machine running it. It never deletes anything.
final class RealHomeProbeTests: XCTestCase {

    func testProbeRealHome() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWEEP_REAL_HOME_PROBE"] == "1",
                          "set SWEEP_REAL_HOME_PROBE=1 to run the read-only probe")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let clock = Date()
        let apps = await AppInventory.scanNested()
        let running = NSWorkspace.shared.runningApplications
        let index = InstalledAppIndex.live(
            apps: apps,
            runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
            runningAppNames: Set(running.compactMap(\.localizedName)),
            runningExecutablePaths: RunningProcesses.executablePaths()
                .union(running.compactMap(\.executableURL?.path))
        )
        let inventoryTime = Date().timeIntervalSince(clock)

        let scanStart = Date()
        let result = OrphanScanner.scanDetailed(home: home, index: index)
        let items = result.items
        let scanTime = Date().timeIntervalSince(scanStart)

        print("PROBE nested inventory: \(apps.count) apps in \(String(format: "%.2f", inventoryTime))s")
        print("PROBE scan: \(items.count) items, \(items.reduce(Int64(0)) { $0 + $1.size }.sweepBytes) in \(String(format: "%.2f", scanTime))s")
        for item in items.sorted(by: { $0.size > $1.size }) {
            print("PROBE  \(item.size.sweepBytes.padding(toLength: 11, withPad: " ", startingAt: 0))"
                + " [\(item.ruleID)] \(item.displayName) — \(item.detail)")
        }

        let findings = result.blocked + LaunchItemAudit.audit(home: home, index: index)
        print("PROBE launch-item findings: \(findings.count)")
        for finding in findings {
            print("PROBE  \(finding.kind.label): \(finding.label) — \(finding.reason)")
        }

        // --- vendor uninstaller hand-off on the real install base ---
        for installed in apps.sorted(by: { $0.name < $1.name }) {
            guard let handoff = VendorUninstaller.handoff(for: installed) else { continue }
            switch handoff {
            case .vendorTool(let url, _):
                print("PROBE handoff \(installed.name): tool -> \(url.path)")
            case .managedByVendor(let vendor, _):
                print("PROBE handoff \(installed.name): \(vendor) tooling required")
            }
        }
        for installed in apps where !UninstallGuard.verdict(for: installed).isAllowed
            && BundleProtection.isSecurityAgent(installed.bundleID) {
            print("PROBE refused: \(installed.name) — \(UninstallGuard.verdict(for: installed).reason ?? "")")
        }

        // --- real liveness probe over everything we would offer ---
        let liveness = FileLiveness()
        let verdicts = await liveness.verdicts(for: items.map(\.url))
        for item in items {
            if let verdict = verdicts[item.url.path], verdict.isInUse {
                print("PROBE in use (would be refused): \(item.url.path) — \(verdict.describedBlocker ?? "?")")
            }
        }
        print("PROBE liveness verdicts: \(verdicts.count) of \(items.count) items, "
            + "complete process view = \(await LsofProbe().processViewIsComplete())")

        // Acceptance criteria: live data must never be offered.
        let offered = Set(items.map { $0.url.path })
        let support = home.appending(path: "Library/Application Support")
        for name in ["Code", "Google", "Adobe", "Microsoft", "Blackmagic Design", "Logi",
                     "Dropbox", "Cursor", "Claude", "Electron", "CEF", "AddressBook",
                     "CrashReporter", "CloudDocs", "Knowledge", "FileProvider", "Spotlight"] {
            XCTAssertFalse(offered.contains(support.appending(path: name).path),
                           "must never offer \(name)")
        }
        // Machine-dependent, so a note rather than an assertion: on the machine
        // this was written for, Adobe/CameraRaw (679 MB) had been written two
        // months earlier and must stay, while Adobe/AcroCef (488 MB, untouched
        // for 11 months) is the real find.
        if offered.contains(support.appending(path: "Adobe/CameraRaw").path) {
            print("PROBE note: Adobe/CameraRaw is being offered — check its age")
        }
        for path in offered {
            XCTAssertFalse(path.contains("state.vscdb"), "offered live editor state: \(path)")
            XCTAssertFalse(path.contains("Bookmarks"), "offered browser bookmarks: \(path)")
        }
    }

    /// Read-only: what the in-use and ownership safety checks do on this Mac.
    func testProbeSafetyRefinements() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWEEP_REAL_HOME_PROBE"] == "1",
                          "set SWEEP_REAL_HOME_PROBE=1 to run the read-only probe")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = SafetyPolicy(home: home)
        let running = NSWorkspace.shared.runningApplications
        let engine = ScanEngine(policy: policy,
                                runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
                                runningAppNames: Set(running.compactMap(\.localizedName).map { $0.lowercased() }))
        let watched: Set<String> = ["crash-reports", "user-logs", "vscode-caches", "installer-archives", "js-package-caches", "user-caches"]
        let rules = RuleCatalog.rules(home: home, includeSystemDomain: false).filter { watched.contains($0.id) }
        let items = await engine.scanReport(rules: rules).items
        for item in items.sorted(by: { $0.size > $1.size }) where item.ruleID != "user-caches" || item.size > 100_000_000 {
            print("PROBE2 offer \(item.size.sweepBytes.padding(toLength: 10, withPad: " ", startingAt: 0)) [\(item.ruleID)] \(item.url.path)")
        }
        XCTAssertFalse(items.contains { $0.url.path == home.appending(path: "Library/Logs/DiagnosticReports").path })
        XCTAssertFalse(items.contains { policy.isProtected($0.url) })

        let all = items.count
        let collapsed = ScanItem.collapsingNested(items).count
        print("PROBE2 nested collapse: \(all) -> \(collapsed)")

        // Git guard over the configured dev folders.
        // The app's own saved dev folders (read, never written).
        let saved = UserDefaults(suiteName: "com.debroye.sweep")?.stringArray(forKey: "devFolders") ?? []
        let devFolders = (saved.isEmpty ? ["Developer", "Projects", "Code", "dev", "src", "workspace", "CleanUpTool"].map { home.appending(path: $0).path } : saved)
            .map { URL(fileURLWithPath: $0) }
        print("PROBE2 dev folders: \(devFolders.map(\.path))")
        let candidates = ProjectArtifactScanner.artifactCandidates(devFolders: devFolders, policy: policy)
        var kept: [String] = []
        for url in candidates {
            let verdict = ArtifactGitGuard.verdict(for: url)
            if !verdict.isRegenerable { kept.append("\(verdict.reason): \(url.path)") }
        }
        print("PROBE2 artifacts: \(candidates.count) candidates, \(kept.count) kept by Git")
        for line in kept.prefix(40) { print("PROBE2  kept \(line)") }

        // Other installed copies, for every app.
        for app in await AppInventory.scan() {
            let others = OtherAppCopies.find(bundleID: app.bundleID, excluding: app.url)
            if !others.isEmpty {
                print("PROBE2 copies \(app.name): \((others.copies + others.unchecked).map(\.path))")
            }
        }
        print("PROBE2 network mounts: \(OtherAppCopies.networkMountPoints())")
        print("PROBE2 vpn: \(await VPNStatus.current())")
    }
}
