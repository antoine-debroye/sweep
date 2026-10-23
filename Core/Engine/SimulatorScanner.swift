import Foundation

// MARK: - Inventory model

public struct SimulatorDevice: Sendable, Identifiable, Equatable {
    public let id: String            // UDID
    public let name: String
    public let runtimeIdentifier: String
    public let state: String
    public let isAvailable: Bool
    public let dataPath: String
    public let dataPathSize: Int64
    public let logPathSize: Int64
    public let lastBootedAt: Date?

    public var totalSize: Int64 { dataPathSize + logPathSize }
    /// "iOS 26.5" derived from com.apple.CoreSimulator.SimRuntime.iOS-26-5.
    public var runtimeLabel: String { SimulatorScanner.runtimeLabel(runtimeIdentifier) }
}

public struct SimulatorRuntime: Sendable, Identifiable, Equatable {
    public let id: String            // disk-image identifier (what `runtime delete` takes)
    public let runtimeIdentifier: String
    public let platform: String      // iOS / watchOS / tvOS / visionOS
    public let version: String
    public let build: String
    public let state: String         // "Ready", "Unusable - …"
    public let deletable: Bool
    public let sizeBytes: Int64
    /// Root of the on-disk asset this image lives in (a MobileAsset `.asset`
    /// folder or a Cryptex `SimRuntimeBundle-…`). A "Patchable" image is a
    /// patch layered on top of a base image in the SAME asset, so deleting
    /// either image removes the whole asset — and the other image with it.
    public let assetRoot: String?
    public let parentIdentifier: String?
    public var devices: [SimulatorDevice] = []
    public var isNewestForPlatform = false
    /// Other runtimes that share this image's asset (see `assetRoot`). They
    /// can only be removed together.
    public var linkedRuntimeIDs: Set<String> = []

    public init(id: String, runtimeIdentifier: String, platform: String, version: String, build: String,
                state: String, deletable: Bool, sizeBytes: Int64, assetRoot: String? = nil, parentIdentifier: String? = nil) {
        self.id = id
        self.runtimeIdentifier = runtimeIdentifier
        self.platform = platform
        self.version = version
        self.build = build
        self.state = state
        self.deletable = deletable
        self.sizeBytes = sizeBytes
        self.assetRoot = assetRoot
        self.parentIdentifier = parentIdentifier
    }

    public var isReady: Bool { state == "Ready" }
    public var displayName: String { "\(platform) \(version) (\(build))" }
    public var lastBooted: Date? { devices.compactMap(\.lastBootedAt).max() }
    public var devicesSize: Int64 { devices.reduce(0) { $0 + $1.totalSize } }
}

public struct SimulatorInventory: Sendable, Equatable {
    public var runtimes: [SimulatorRuntime] = []
    /// Devices whose runtime is no longer installed (`simctl delete unavailable` territory).
    public var unavailableDevices: [SimulatorDevice] = []

    public init(runtimes: [SimulatorRuntime] = [], unavailableDevices: [SimulatorDevice] = []) {
        self.runtimes = runtimes
        self.unavailableDevices = unavailableDevices
    }

    public var allDevices: [SimulatorDevice] { runtimes.flatMap(\.devices) + unavailableDevices }
    public var runtimesSize: Int64 { runtimes.reduce(0) { $0 + $1.sizeBytes } }
    public var devicesSize: Int64 { allDevices.reduce(0) { $0 + $1.totalSize } }
    public var isEmpty: Bool { runtimes.isEmpty && unavailableDevices.isEmpty }
}

public struct SimulatorSuggestion: Sendable, Equatable {
    public var runtimeIDs: Set<String> = []
    public var deviceIDs: Set<String> = []
}

// MARK: - Scanner

/// Inventory of simulator runtimes and devices via `xcrun simctl`. Removal
/// goes through simctl too (never a raw rm of CoreSimulator folders), so
/// CoreSimulator's own bookkeeping stays consistent.
public enum SimulatorScanner {
    static let xcrun = "/usr/bin/xcrun"

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: xcrun)
            && FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator")
    }

    public typealias Runner = @Sendable (_ path: String, _ args: [String], _ timeout: TimeInterval) async -> ProcessResult

    /// Whether simctl can run without macOS stepping in. `/usr/bin/xcrun` is a
    /// shim: with no developer tools it opens the Command Line Tools installer,
    /// with only the Command Line Tools there is no simctl, and with an Xcode
    /// that hasn't finished its first-launch setup simctl asks for an admin
    /// password to install components. Ask the selected Xcode directly instead.
    public static func toolsReady(
        run: Runner = { await ProcessRunner.run($0, $1, timeout: $2) },
        fileExists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> Bool {
        let select = await run("/usr/bin/xcode-select", ["-p"], 5)
        let developerDir = select.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard select.status == 0, !developerDir.isEmpty,
              fileExists(developerDir + "/usr/bin/simctl"),
              fileExists(developerDir + "/usr/bin/xcodebuild") else { return false }
        // Exit 0 means the first-launch setup is done; anything else (setup
        // pending, timed out) means leave the simulator tools alone.
        let firstLaunch = await run(developerDir + "/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"], 20)
        return firstLaunch.status == 0
    }

    public static func inventory() async -> SimulatorInventory {
        guard isAvailable, await toolsReady() else { return SimulatorInventory() }
        // A wedged CoreSimulatorService can leave simctl waiting forever.
        let runtimesResult = await ProcessRunner.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        let devicesResult = await ProcessRunner.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
        guard runtimesResult.status == 0, devicesResult.status == 0 else { return SimulatorInventory() }
        let runtimes = (try? parseRuntimes(Data(runtimesResult.stdout.utf8))) ?? []
        let devices = (try? parseDevices(Data(devicesResult.stdout.utf8))) ?? []
        return assemble(runtimes: runtimes, devices: devices)
    }

    // MARK: Parsing (pure, unit-tested)

    private struct RuntimeJSON: Decodable {
        let identifier: String
        let runtimeIdentifier: String
        let platformIdentifier: String
        let version: String
        let build: String
        let state: String
        let deletable: Bool?
        let sizeBytes: Int64?
        let path: String?
        let parentIdentifier: String?
        let parentImagePath: String?
        let parentMountPath: String?
    }

    private struct DeviceJSON: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPath: String?
        let dataPathSize: Int64?
        let logPathSize: Int64?
        let lastBootedAt: String?
    }

    private struct DeviceListJSON: Decodable {
        let devices: [String: [DeviceJSON]]
    }

    public static func parseRuntimes(_ data: Data) throws -> [SimulatorRuntime] {
        let dict = try JSONDecoder().decode([String: RuntimeJSON].self, from: data)
        return dict.values.map { r in
            SimulatorRuntime(
                id: r.identifier,
                runtimeIdentifier: r.runtimeIdentifier,
                platform: platformName(r.platformIdentifier),
                version: r.version,
                build: r.build,
                state: r.state,
                deletable: r.deletable ?? true,
                sizeBytes: r.sizeBytes ?? 0,
                assetRoot: assetRoot(for: [r.path, r.parentImagePath, r.parentMountPath]),
                parentIdentifier: r.parentIdentifier
            )
        }
        .sorted { isNewer($0, than: $1) }
    }

    /// The shared on-disk unit an image belongs to: the enclosing
    /// `….asset` folder, or a Cryptex `SimRuntimeBundle-…` folder.
    static func assetRoot(for paths: [String?]) -> String? {
        for path in paths.compactMap({ $0 }) where !path.isEmpty {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if let index = components.firstIndex(where: { $0.hasSuffix(".asset") || $0.hasPrefix("SimRuntimeBundle-") }) {
                return components[...index].joined(separator: "/")
            }
        }
        return nil
    }

    /// Deterministic "newer" ordering: platform, then version, then build —
    /// two disk images of the same version (a Ready one and its duplicate)
    /// must always resolve the same way.
    static func isNewer(_ lhs: SimulatorRuntime, than rhs: SimulatorRuntime) -> Bool {
        if lhs.platform != rhs.platform { return lhs.platform < rhs.platform }
        switch compareVersion(lhs.version, rhs.version) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame:
            if lhs.build != rhs.build { return lhs.build.localizedStandardCompare(rhs.build) == .orderedDescending }
            return lhs.id < rhs.id
        }
    }

    public static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        let list = try JSONDecoder().decode(DeviceListJSON.self, from: data)
        let iso = ISO8601DateFormatter()
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in list.devices {
            for d in entries {
                devices.append(SimulatorDevice(
                    id: d.udid,
                    name: d.name,
                    runtimeIdentifier: runtime,
                    state: d.state,
                    isAvailable: d.isAvailable ?? false,
                    dataPath: d.dataPath ?? "",
                    dataPathSize: d.dataPathSize ?? 0,
                    logPathSize: d.logPathSize ?? 0,
                    lastBootedAt: d.lastBootedAt.flatMap { iso.date(from: $0) }
                ))
            }
        }
        return devices.sorted { $0.totalSize > $1.totalSize }
    }

    /// Attaches devices to their runtime (the Ready one when two disk images
    /// share a runtime identifier), marks the newest Ready runtime per
    /// platform, and collects devices whose runtime is gone.
    public static func assemble(runtimes: [SimulatorRuntime], devices: [SimulatorDevice]) -> SimulatorInventory {
        var runtimes = runtimes.sorted { isNewer($0, than: $1) }
        var unavailable: [SimulatorDevice] = []

        for device in devices {
            let candidates = runtimes.indices.filter { runtimes[$0].runtimeIdentifier == device.runtimeIdentifier }
            guard let index = candidates.first(where: { runtimes[$0].isReady }) ?? candidates.first else {
                unavailable.append(device)
                continue
            }
            runtimes[index].devices.append(device)
        }

        // Images that share an asset (or name another image as parent) are one
        // deletion unit.
        for i in runtimes.indices {
            for j in runtimes.indices where i != j {
                let sameAsset = runtimes[i].assetRoot != nil && runtimes[i].assetRoot == runtimes[j].assetRoot
                let parentLink = runtimes[i].parentIdentifier == runtimes[j].id || runtimes[j].parentIdentifier == runtimes[i].id
                if sameAsset || parentLink { runtimes[i].linkedRuntimeIDs.insert(runtimes[j].id) }
            }
        }

        for platform in Set(runtimes.map(\.platform)) {
            let ready = runtimes.indices.filter { runtimes[$0].platform == platform && runtimes[$0].isReady }
            // Sorted newest-first above, so the first Ready one is the newest.
            guard let newest = ready.first else { continue }
            runtimes[newest].isNewestForPlatform = true
        }
        return SimulatorInventory(runtimes: runtimes, unavailableDevices: unavailable)
    }

    // MARK: Suggestions

    /// What is safe to offer by default: unusable runtimes; runtimes that are
    /// not the newest for their platform and have had no device booted in
    /// `staleDays`; devices never booted (but carrying data) or not booted in
    /// `staleDays` on a runtime that stays. Nothing is ever pre-selected —
    /// this only powers a "Select suggested" button.
    public static func suggest(_ inventory: SimulatorInventory, staleDays: Int = 60, now: Date = Date()) -> SimulatorSuggestion {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        var suggestion = SimulatorSuggestion()

        for runtime in inventory.runtimes where runtime.deletable {
            if !runtime.isReady {
                suggestion.runtimeIDs.insert(runtime.id)
                continue
            }
            if runtime.isNewestForPlatform { continue }
            let lastBooted = runtime.lastBooted ?? .distantPast
            if lastBooted < cutoff { suggestion.runtimeIDs.insert(runtime.id) }
        }
        // An image that shares its asset with a runtime we keep cannot go —
        // removing it would take the kept runtime with it.
        var pruned = true
        while pruned {
            pruned = false
            for runtime in inventory.runtimes where suggestion.runtimeIDs.contains(runtime.id) {
                if !runtime.linkedRuntimeIDs.isSubset(of: suggestion.runtimeIDs) {
                    suggestion.runtimeIDs.remove(runtime.id)
                    pruned = true
                }
            }
        }

        for runtime in inventory.runtimes where !suggestion.runtimeIDs.contains(runtime.id) {
            for device in runtime.devices where device.isAvailable && device.state != "Booted" {
                if let booted = device.lastBootedAt {
                    if booted < cutoff { suggestion.deviceIDs.insert(device.id) }
                } else if device.totalSize > 100_000_000 {
                    suggestion.deviceIDs.insert(device.id)
                }
            }
        }
        for device in inventory.unavailableDevices { suggestion.deviceIDs.insert(device.id) }
        return suggestion
    }

    // MARK: Removal

    public struct RemovalResult: Sendable {
        public var removedRuntimes: [SimulatorRuntime] = []
        public var removedDevices: [SimulatorDevice] = []
        public var errors: [String] = []
        public var freed: Int64 {
            removedRuntimes.reduce(0) { $0 + $1.sizeBytes + $1.devicesSize }
                + removedDevices.reduce(0) { $0 + $1.totalSize }
        }
    }

    /// Selected devices that must be deleted explicitly: a device only goes
    /// away with its runtime when EVERY image carrying that runtime
    /// identifier is being removed.
    public static func devicesToDeleteExplicitly(
        selectedDevices: [SimulatorDevice],
        removingRuntimes: [SimulatorRuntime],
        inventory: SimulatorInventory
    ) -> [SimulatorDevice] {
        let removingIDs = Set(removingRuntimes.map(\.id))
        return selectedDevices.filter { device in
            let images = inventory.runtimes.filter { $0.runtimeIdentifier == device.runtimeIdentifier }
            let allImagesRemoved = !images.isEmpty && images.allSatisfy { removingIDs.contains($0.id) }
            return !allImagesRemoved
        }
    }

    /// Deletes devices first (so the sizes are attributable), then runtimes.
    /// A runtime whose linked images are not all in the batch is refused —
    /// deleting it would silently remove the others. Devices left
    /// unavailable are NOT swept here: a runtime that is merely missing
    /// (re-downloadable) must not cost the user their device data.
    public static func remove(runtimes: [SimulatorRuntime], devices: [SimulatorDevice]) async -> RemovalResult {
        var result = RemovalResult()
        let batch = Set(runtimes.map(\.id))
        var runtimes = runtimes
        for runtime in runtimes where !runtime.linkedRuntimeIDs.isSubset(of: batch) {
            result.errors.append("\(runtime.displayName) shares its disk image with another installed runtime; remove them together.")
        }
        runtimes.removeAll { !$0.linkedRuntimeIDs.isSubset(of: batch) }
        for device in devices {
            let r = await ProcessRunner.run(xcrun, ["simctl", "delete", device.id], timeout: 120)
            if r.status == 0 {
                result.removedDevices.append(device)
            } else {
                result.errors.append("\(device.name): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
            }
        }
        for runtime in runtimes {
            let r = await ProcessRunner.run(xcrun, ["simctl", "runtime", "delete", runtime.id], timeout: 300)
            if r.status == 0 {
                result.removedRuntimes.append(runtime)
            } else {
                result.errors.append("\(runtime.displayName): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
            }
        }
        return result
    }

    // MARK: Helpers

    static func platformName(_ identifier: String) -> String {
        if identifier.contains("watch") { return "watchOS" }
        if identifier.contains("appletv") { return "tvOS" }
        if identifier.contains("xr") || identifier.contains("vision") { return "visionOS" }
        return "iOS"
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    public static func runtimeLabel(_ runtimeIdentifier: String) -> String {
        guard let tail = runtimeIdentifier.split(separator: ".").last else { return runtimeIdentifier }
        let parts = tail.split(separator: "-")
        guard parts.count >= 2 else { return String(tail) }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }

    static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(l, r) where a != b { return a < b ? .orderedAscending : .orderedDescending }
        if l.count == r.count { return .orderedSame }
        return l.count < r.count ? .orderedAscending : .orderedDescending
    }
}
