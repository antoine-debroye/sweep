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

    func testSameVersionBuildsResolveDeterministically() throws {
        // Two Ready images of iOS 26.5 with different builds, listed in either
        // order: the higher build is always "newest" and receives the devices.
        let a = #"{"build":"23F73","identifier":"X-73","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":1,"state":"Ready","version":"26.5"}"#
        let b = #"{"build":"23F77","identifier":"X-77","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":1,"state":"Ready","version":"26.5"}"#
        let devices = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"D1","name":"iPhone","state":"Shutdown","isAvailable":true}]}}"#
        for json in ["{\"X-73\":\(a),\"X-77\":\(b)}", "{\"X-77\":\(b),\"X-73\":\(a)}"] {
            let inv = SimulatorScanner.assemble(
                runtimes: try SimulatorScanner.parseRuntimes(Data(json.utf8)),
                devices: try SimulatorScanner.parseDevices(Data(devices.utf8))
            )
            XCTAssertEqual(inv.runtimes.map(\.id), ["X-77", "X-73"])
            XCTAssertTrue(inv.runtimes[0].isNewestForPlatform)
            XCTAssertFalse(inv.runtimes[1].isNewestForPlatform)
            XCTAssertEqual(inv.runtimes[0].devices.map(\.id), ["D1"])
            let s = SimulatorScanner.suggest(inv)
            XCTAssertEqual(s.runtimeIDs, ["X-73"], "the older build with no booted devices is the one to suggest")
        }
    }

    func testImagesSharingAnAssetAreOneUnit() throws {
        // The real 2026-09-09 incident: iOS 26.5 build 23F73 was the base
        // image inside a MobileAsset and 23F77 a patch on top of it. 23F73
        // had no devices and was suggested; deleting it removed 23F77 too.
        let asset = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc123.asset/AssetData"
        let json = """
        {
          "BASE-73": {"build":"23F73","identifier":"BASE-73","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":8000000000,"state":"Ready","version":"26.5","kind":"Cryptex Disk Image","path":"\(asset)/Restore/1.dmg"},
          "PATCH-77": {"build":"23F77","identifier":"PATCH-77","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","sizeBytes":8000000000,"state":"Ready","version":"26.5","kind":"Patchable Cryptex Disk Image","path":"/Library/Developer/CoreSimulator/Cryptex/Images/patched/2.dmg","parentImagePath":"\(asset)/Restore/1.dmg","parentMountPath":"\(asset)"},
          "OLD-18": {"build":"22E238","identifier":"OLD-18","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-4","sizeBytes":7000000000,"state":"Ready","version":"18.4","kind":"Cryptex Disk Image","path":"/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-XYZ/Restore/3.dmg","parentIdentifier":"XYZ"}
        }
        """
        let devices = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"D1","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true,"dataPathSize":4000000000,"lastBootedAt":"2026-09-08T00:00:00Z"}]}}"#
        let inv = SimulatorScanner.assemble(
            runtimes: try SimulatorScanner.parseRuntimes(Data(json.utf8)),
            devices: try SimulatorScanner.parseDevices(Data(devices.utf8))
        )
        let base = try XCTUnwrap(inv.runtimes.first { $0.id == "BASE-73" })
        let patch = try XCTUnwrap(inv.runtimes.first { $0.id == "PATCH-77" })
        XCTAssertEqual(base.assetRoot, patch.assetRoot)
        XCTAssertEqual(base.linkedRuntimeIDs, ["PATCH-77"])
        XCTAssertEqual(patch.linkedRuntimeIDs, ["BASE-73"])
        XCTAssertTrue(patch.isNewestForPlatform)
        XCTAssertTrue(try XCTUnwrap(inv.runtimes.first { $0.id == "OLD-18" }).linkedRuntimeIDs.isEmpty)

        let s = SimulatorScanner.suggest(inv, staleDays: 60, now: Date(timeIntervalSince1970: 1_788_998_400))
        XCTAssertFalse(s.runtimeIDs.contains("BASE-73"), "the base image of a kept runtime must never be suggested")
        XCTAssertFalse(s.runtimeIDs.contains("PATCH-77"))
        XCTAssertTrue(s.runtimeIDs.contains("OLD-18"))
    }

    func testPartialUnitRemovalIsRefusedAndDevicesPartitioned() async throws {
        var base = SimulatorRuntime(id: "BASE", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", platform: "iOS",
                                    version: "26.5", build: "23F73", state: "Ready", deletable: true, sizeBytes: 1, assetRoot: "/a.asset")
        var patch = SimulatorRuntime(id: "PATCH", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", platform: "iOS",
                                     version: "26.5", build: "23F77", state: "Ready", deletable: true, sizeBytes: 1, assetRoot: "/a.asset")
        base.linkedRuntimeIDs = ["PATCH"]; patch.linkedRuntimeIDs = ["BASE"]
        let device = SimulatorDevice(id: "D1", name: "iPhone", runtimeIdentifier: patch.runtimeIdentifier, state: "Shutdown",
                                     isAvailable: true, dataPath: "/d", dataPathSize: 10, logPathSize: 0, lastBootedAt: nil)
        let inv = SimulatorInventory(runtimes: [patch, base])

        // Removing only the base is refused before any simctl call.
        let result = await SimulatorScanner.remove(runtimes: [base], devices: [])
        XCTAssertTrue(result.removedRuntimes.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("shares its disk image"))

        // A selected device is only implied when EVERY image of its runtime goes.
        XCTAssertEqual(SimulatorScanner.devicesToDeleteExplicitly(selectedDevices: [device], removingRuntimes: [base], inventory: inv).map(\.id), ["D1"])
        XCTAssertTrue(SimulatorScanner.devicesToDeleteExplicitly(selectedDevices: [device], removingRuntimes: [base, patch], inventory: inv).isEmpty)
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
