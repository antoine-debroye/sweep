import XCTest
@testable import SweepCore

/// The safety gate: if any of these fail, the build must not ship.
final class SafetyTests: XCTestCase {
    let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Protected subtrees

    func testEssentialUserDataIsProtected() {
        let policy = SafetyPolicy()
        let mustBeProtected = [
            home.appending(path: "Documents"),
            home.appending(path: "Documents/taxes/2026.pdf"),
            home.appending(path: "Desktop"),
            home.appending(path: "Desktop/screenshot.png"),
            home.appending(path: "Pictures/Photos Library.photoslibrary"),
            home.appending(path: "Music"),
            home.appending(path: "Movies/holiday.mp4"),
            home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/notes.txt"),
            home.appending(path: "Library/CloudStorage/Dropbox/contract.pdf"),
            home.appending(path: "Library/Keychains/login.keychain-db"),
            home.appending(path: "Library/Mail/V10/inbox.mbox"),
            home.appending(path: "Library/Messages/chat.db"),
            home.appending(path: ".ssh/id_ed25519"),
            home.appending(path: ".gnupg/private-keys-v1.d"),
            home.appending(path: ".aws/credentials"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/usr/bin/ssh"),
            URL(fileURLWithPath: "/private/etc/hosts"),
            URL(fileURLWithPath: "/Library/LaunchDaemons/com.something.plist"),
        ]
        for url in mustBeProtected {
            XCTAssertTrue(policy.isProtected(url), "MUST be protected: \(url.path)")
        }
    }

    func testCleaningRootsAreExactProtectedButChildrenAllowed() {
        let policy = SafetyPolicy()
        // The container folders themselves may never be deleted…
        XCTAssertTrue(policy.isProtected(home.appending(path: "Library/Caches")))
        XCTAssertTrue(policy.isProtected(home.appending(path: "Library")))
        XCTAssertTrue(policy.isProtected(home))
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: "/")))
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: "/Library/Caches")))
        // …but the junk inside them is fair game.
        XCTAssertFalse(policy.isProtected(home.appending(path: "Library/Caches/com.somevendor.someapp")))
        XCTAssertFalse(policy.isProtected(home.appending(path: "Library/Logs/old.log")))
        XCTAssertFalse(policy.isProtected(URL(fileURLWithPath: "/Library/Caches/com.vendor.tool")))
    }

    func testCaseVariantsAndDotSegmentsAreStillProtected() {
        let policy = SafetyPolicy()
        XCTAssertTrue(policy.isProtected(home.appending(path: "DOCUMENTS/file.txt")))
        XCTAssertTrue(policy.isProtected(home.appending(path: "Library/Caches/../../Documents/file.txt")))
    }

    // MARK: - Rules can never emit protected paths

    func testNoCatalogRuleTargetsAProtectedPathAsDeletable() {
        let policy = SafetyPolicy()
        for rule in RuleCatalog.rules() {
            for path in rule.paths {
                if rule.contentsOnly {
                    // The root may be an exact-protected container; that's fine
                    // because only children are offered. It must never sit
                    // INSIDE a protected subtree though.
                    XCTAssertFalse(
                        isInsideProtectedSubtree(path, policy: policy),
                        "Rule \(rule.id) scans inside a protected subtree: \(path.path)"
                    )
                } else {
                    XCTAssertFalse(
                        policy.isProtected(path),
                        "Rule \(rule.id) would delete a protected path: \(path.path)"
                    )
                }
            }
        }
    }

    private func isInsideProtectedSubtree(_ url: URL, policy: SafetyPolicy) -> Bool {
        let canonical = SafetyPolicy.canonical(url.path)
        return policy.protectedSubtrees.contains { canonical == $0 || canonical.hasPrefix($0 + "/") }
    }

    func testAutoTrimRulesAreStrictlySafeUserDomain() {
        let rules = RuleCatalog.autoTrimRules(minAgeDays: 30)
        XCTAssertFalse(rules.isEmpty)
        for rule in rules {
            XCTAssertEqual(rule.tier, .safe, "auto-trim must only include Safe rules (\(rule.id))")
            XCTAssertEqual(rule.domain, .user, "auto-trim must never touch system domain (\(rule.id))")
            XCTAssertNotEqual(rule.category, .trash, "auto-trim must never empty the Trash")
            XCTAssertFalse(rule.forcePermanent, "auto-trim must stay reversible (\(rule.id))")
            XCTAssertGreaterThanOrEqual(rule.minAgeDays, 30, "auto-trim age gate must be ≥ requested (\(rule.id))")
        }
    }

    // MARK: - Privileged path policy

    func testPrivilegedPolicyRejectsDangerousPaths() {
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/Library/Caches"))       // root itself
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/System/Library/Kernels/kernel"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/Users/antoine/Documents"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/Library/Caches/../LaunchDaemons/evil.plist"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("relative/path"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/private/var/db/dslocal"))
        XCTAssertTrue(PrivilegedPathPolicy.isAllowed("/Library/Caches/com.vendor.app"))
        XCTAssertTrue(PrivilegedPathPolicy.isAllowed("/Library/Logs/SomeTool/log.txt"))
        XCTAssertTrue(PrivilegedPathPolicy.isAllowed("/private/var/log/system.log.0.gz"))
    }

    func testAslConfCarveOutIsNotBypassableViaVarSpelling() {
        // The denied file must be rejected under BOTH spellings; checking only
        // the raw path let "/var/log/asl.conf" through before /private was added.
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/private/var/log/asl.conf"))
        XCTAssertFalse(PrivilegedPathPolicy.isAllowed("/var/log/asl.conf"))
        // A normal rotated log in the same directory stays allowed.
        XCTAssertTrue(PrivilegedPathPolicy.isAllowed("/var/log/system.log"))
    }

    func testInTrashDetectionIsAnchoredToRealTrash() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(Cleaner.isInTrash(home.appending(path: ".Trash/old.zip")))
        XCTAssertTrue(Cleaner.isInTrash(URL(fileURLWithPath: "/Volumes/Ext/.Trashes/501/x")))
        // Look-alike folder names must NOT be treated as Trash (they'd be force
        // deleted permanently, defeating undo).
        XCTAssertFalse(Cleaner.isInTrash(home.appending(path: "Library/Caches/.trashcan/blob")))
        XCTAssertFalse(Cleaner.isInTrash(home.appending(path: ".trash-backups/keep")))
    }

    // MARK: - Uninstall guard

    func testUninstallGuardOnlyAllowsAppBundlesInApplications() {
        XCTAssertTrue(UninstallGuard.mayRemoveAppBundle(URL(fileURLWithPath: "/Applications/SomeApp.app")))
        XCTAssertFalse(UninstallGuard.mayRemoveAppBundle(URL(fileURLWithPath: "/Applications/Utilities")))
        XCTAssertFalse(UninstallGuard.mayRemoveAppBundle(URL(fileURLWithPath: "/System/Applications/Mail.app")))
        XCTAssertFalse(UninstallGuard.mayRemoveAppBundle(home.appending(path: "Documents/backup.app")))
    }

    // MARK: - Whitelist

    func testWhitelistMatchesPrefixes() {
        let target = home.appending(path: "Library/Caches/com.jetbrains.intellij")
        XCTAssertTrue(SafetyPolicy.isWhitelisted(target, whitelist: [home.appending(path: "Library/Caches/com.jetbrains.intellij").path]))
        XCTAssertTrue(SafetyPolicy.isWhitelisted(
            target.appending(path: "index"),
            whitelist: [home.appending(path: "Library/Caches/com.jetbrains.intellij").path]
        ))
        XCTAssertFalse(SafetyPolicy.isWhitelisted(target, whitelist: [home.appending(path: "Library/Caches/other").path]))
        XCTAssertFalse(SafetyPolicy.isWhitelisted(target, whitelist: []))
    }
}
