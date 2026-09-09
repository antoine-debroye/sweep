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
    public var devices: [SimulatorDevice] = []
    public var isNewestForPlatform = false

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

    public static func inventory() async -> SimulatorInventory {
        guard isAvailable else { return SimulatorInventory() }
        let runtimesResult = await ProcessRunner.run(xcrun, ["simctl", "runtime", "list", "-j"])
        let devicesResult = await ProcessRunner.run(xcrun, ["simctl", "list", "devices", "-j"])
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
                sizeBytes: r.sizeBytes ?? 0
            )
        }
        .sorted { isNewer($0, than: $1) }
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

    /// Deletes devices first (so the sizes are attributable), then runtimes,
    /// then sweeps devices left unavailable by the runtime removals.
    public static func remove(runtimes: [SimulatorRuntime], devices: [SimulatorDevice]) async -> RemovalResult {
        var result = RemovalResult()
        for device in devices {
            let r = await ProcessRunner.run(xcrun, ["simctl", "delete", device.id])
            if r.status == 0 {
                result.removedDevices.append(device)
            } else {
                result.errors.append("\(device.name): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
            }
        }
        for runtime in runtimes {
            let r = await ProcessRunner.run(xcrun, ["simctl", "runtime", "delete", runtime.id])
            if r.status == 0 {
                result.removedRuntimes.append(runtime)
            } else {
                result.errors.append("\(runtime.displayName): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
            }
        }
        if !result.removedRuntimes.isEmpty {
            _ = await ProcessRunner.run(xcrun, ["simctl", "delete", "unavailable"])
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
