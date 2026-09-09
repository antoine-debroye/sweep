import XCTest
@testable import SweepCore

/// Parsing and suggestion logic only — no simctl calls, nothing is deleted.
final class SimulatorScannerTests: XCTestCase {
    let runtimesJSON = """
    {
      "AAAA-READY-26-5": {"build":"23F77","deletable":true,"identifier":"AAAA-READY-26-5","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":8000000000,"state":"Ready","version":"26.5"},
      "BBBB-DUP-26-5":   {"build":"23F77","deletable":true,"identifier":"BBBB-DUP-26-5","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":8000000000,"state":"Unusable - Other Failure: Duplicate of AAAA-READY-26-5","version":"26.5"},
      "CCCC-OLD-18-4":   {"build":"22E238","deletable":true,"identifier":"CCCC-OLD-18-4","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-4","sizeBytes":7000000000,"state":"Ready","version":"18.4"},
      "DDDD-OLD-26-0":   {"build":"23A8464","deletable":true,"identifier":"DDDD-OLD-26-0","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","sizeBytes":7500000000,"state":"Ready","version":"26.0.1"},
      "EEEE-WATCH":      {"build":"22T250","deletable":true,"identifier":"EEEE-WATCH","platformIdentifier":"com.apple.platform.watchsimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-4","sizeBytes":4000000000,"state":"Ready","version":"11.4"}
    }
    """

    func devicesJSON(now: Date) -> String {
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-2 * 86_400))
        let stale = iso.string(from: now.addingTimeInterval(-120 * 86_400))
        return """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid":"D1","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true,"dataPath":"/d/D1/data","dataPathSize":4000000000,"logPathSize":1000,"lastBootedAt":"\(recent)"},
            {"udid":"D2","name":"iPhone Air","state":"Shutdown","isAvailable":true,"dataPath":"/d/D2/data","dataPathSize":20000000,"logPathSize":0},
            {"udid":"D3","name":"iPad Pro","state":"Shutdown","isAvailable":true,"dataPath":"/d/D3/data","dataPathSize":2000000000,"logPathSize":0,"lastBootedAt":"\(stale)"},
            {"udid":"D4","name":"iPhone 17","state":"Booted","isAvailable":true,"dataPath":"/d/D4/data","dataPathSize":3000000000,"logPathSize":0,"lastBootedAt":"\(stale)"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
            {"udid":"D5","name":"iPhone 16","state":"Shutdown","isAvailable":true,"dataPath":"/d/D5/data","dataPathSize":3300000000,"logPathSize":0,"lastBootedAt":"\(stale)"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"udid":"D6","name":"iPhone 16e","state":"Shutdown","isAvailable":true,"dataPath":"/d/D6/data","dataPathSize":500000000,"logPathSize":0,"lastBootedAt":"\(recent)"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"udid":"D7","name":"iPhone 15","state":"Shutdown","isAvailable":false,"dataPath":"/d/D7/data","dataPathSize":900000000,"logPathSize":0}
          ]
        }}
        """
    }

    func testParsingAndAssembly() throws {
        let now = Date()
        let runtimes = try SimulatorScanner.parseRuntimes(Data(runtimesJSON.utf8))
        let devices = try SimulatorScanner.parseDevices(Data(devicesJSON(now: now).utf8))
        XCTAssertEqual(runtimes.count, 5)
        XCTAssertEqual(devices.count, 7)

        let inv = SimulatorScanner.assemble(runtimes: runtimes, devices: devices)
        let ready265 = try XCTUnwrap(inv.runtimes.first { $0.id == "AAAA-READY-26-5" })
        let dup265 = try XCTUnwrap(inv.runtimes.first { $0.id == "BBBB-DUP-26-5" })
        XCTAssertEqual(Set(ready265.devices.map(\.id)), ["D1", "D2", "D3", "D4"], "devices attach to the Ready image, not the duplicate")
        XCTAssertTrue(dup265.devices.isEmpty)
        XCTAssertTrue(ready265.isNewestForPlatform)
        XCTAssertFalse(try XCTUnwrap(inv.runtimes.first { $0.id == "CCCC-OLD-18-4" }).isNewestForPlatform)
        XCTAssertTrue(try XCTUnwrap(inv.runtimes.first { $0.id == "EEEE-WATCH" }).isNewestForPlatform)
        XCTAssertEqual(inv.unavailableDevices.map(\.id), ["D7"], "device on an uninstalled runtime is unavailable")
        XCTAssertEqual(ready265.displayName, "iOS 26.5 (23F77)")
        XCTAssertEqual(devices.first { $0.id == "D1" }?.runtimeLabel, "iOS 26.5")
        XCTAssertEqual(inv.runtimesSize, 34_500_000_000)
    }

    func testSuggestionsNeverIncludeNewestReadyRuntimeOrBootedDevice() throws {
        let now = Date()
        let inv = SimulatorScanner.assemble(
            runtimes: try SimulatorScanner.parseRuntimes(Data(runtimesJSON.utf8)),
            devices: try SimulatorScanner.parseDevices(Data(devicesJSON(now: now).utf8))
        )
        let s = SimulatorScanner.suggest(inv, staleDays: 60, now: now)

        XCTAssertTrue(s.runtimeIDs.contains("BBBB-DUP-26-5"), "unusable duplicate is always suggested")
        XCTAssertTrue(s.runtimeIDs.contains("CCCC-OLD-18-4"), "old runtime whose devices haven't booted in 60d")
        XCTAssertFalse(s.runtimeIDs.contains("DDDD-OLD-26-0"), "old runtime booted 2 days ago stays")
        XCTAssertFalse(s.runtimeIDs.contains("AAAA-READY-26-5"), "newest per platform stays")
        XCTAssertFalse(s.runtimeIDs.contains("EEEE-WATCH"), "newest watchOS stays even if never booted")

        XCTAssertFalse(s.deviceIDs.contains("D1"), "recently booted device stays")
        XCTAssertFalse(s.deviceIDs.contains("D2"), "never-booted device with negligible data is not worth suggesting")
        XCTAssertTrue(s.deviceIDs.contains("D3"), "stale device on a kept runtime")
        XCTAssertFalse(s.deviceIDs.contains("D4"), "a Booted device is never suggested")
        XCTAssertFalse(s.deviceIDs.contains("D5"), "device goes away with its suggested runtime; not listed twice")
        XCTAssertFalse(s.deviceIDs.contains("D6"))
        XCTAssertTrue(s.deviceIDs.contains("D7"), "unavailable device is suggested")
    }

    func testVersionAndLabelHelpers() {
        XCTAssertEqual(SimulatorScanner.compareVersion("26.5", "26.4.1"), .orderedDescending)
        XCTAssertEqual(SimulatorScanner.compareVersion("18.4", "26.0.1"), .orderedAscending)
        XCTAssertEqual(SimulatorScanner.compareVersion("26.0", "26.0"), .orderedSame)
        XCTAssertEqual(SimulatorScanner.runtimeLabel("com.apple.CoreSimulator.SimRuntime.watchOS-11-4"), "watchOS 11.4")
        XCTAssertEqual(SimulatorScanner.platformName("com.apple.platform.xrsimulator"), "visionOS")
    }

    func testMalformedJSONYieldsNothing() {
        XCTAssertThrowsError(try SimulatorScanner.parseRuntimes(Data("nope".utf8)))
        XCTAssertThrowsError(try SimulatorScanner.parseDevices(Data("{}".utf8)))
    }
}
