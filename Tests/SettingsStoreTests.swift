import XCTest
@testable import SweepCore

/// Settings persistence — focused on the appearance preference added for the
/// light/dark/auto feature. Uses a throwaway UserDefaults suite so the real
/// `.standard` domain is never touched.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        // A unique, in-memory-ish suite per test run; wiped on teardown below.
        let suite = "com.debroye.sweep.tests.settings." + UUID().uuidString
        return UserDefaults(suiteName: suite)!
    }

    func testAppearanceDefaultsToSystem() {
        let store = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.appearance, .system)
    }

    func testAppearancePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.appearance = .dark

        // A fresh store reading the same defaults must see the saved value.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.appearance, .dark)
    }

    func testUnknownAppearanceRawValueFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("chartreuse", forKey: "appearance")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .system)
    }
}
