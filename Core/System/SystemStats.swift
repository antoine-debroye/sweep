import Foundation
import Darwin

// MARK: - Memory

public struct MemorySnapshot: Sendable {
    public let date: Date
    public let total: Int64
    public let free: Int64
    public let active: Int64
    public let inactive: Int64
    public let wired: Int64
    public let compressed: Int64
    public let appMemory: Int64

    public var used: Int64 { appMemory + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public enum PressureLevel: String, Sendable {
        case normal, warning, critical

        public var label: String {
            switch self {
            case .normal: "Normal"
            case .warning: "Elevated"
            case .critical: "Critical"
            }
        }
    }

    public var pressure: PressureLevel {
        switch usedFraction {
        case ..<0.7: .normal
        case ..<0.9: .warning
        default: .critical
        }
    }
}

public enum MemoryStats {
    /// Cached host port. `mach_host_self()` hands back a send right whose user
    /// reference count is bumped on every call; sampling twice a second would
    /// leak references forever, so we take it once for the process lifetime.
    private static let hostPort = mach_host_self()

    public static func sample() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var hostPageSize: vm_size_t = 0
        host_page_size(hostPort, &hostPageSize)
        let pageSize = Int64(hostPageSize > 0 ? hostPageSize : 16_384)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let free = Int64(stats.free_count) * pageSize
        let active = Int64(stats.active_count) * pageSize
        let inactive = Int64(stats.inactive_count) * pageSize
        let wired = Int64(stats.wire_count) * pageSize
        let compressed = Int64(stats.compressor_page_count) * pageSize
        let appMemory = max(0, Int64(stats.internal_page_count) * pageSize - Int64(stats.purgeable_count) * pageSize)

        return MemorySnapshot(
            date: Date(),
            total: total,
            free: free,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            appMemory: appMemory
        )
    }
}

public struct TopProcess: Sendable, Identifiable {
    public let pid: Int
    public let name: String
    public let memoryBytes: Int64
    public var id: Int { pid }
}

public enum ProcessStats {
    /// Top memory consumers via `ps` (robust, no special entitlements needed).
    public static func topByMemory(limit: Int = 10) async -> [TopProcess] {
        let result = await ProcessRunner.run("/bin/ps", ["axm", "-o", "pid=,rss=,comm="])
        guard result.status == 0 else { return [] }
        var processes: [TopProcess] = []
        for line in result.stdout.split(separator: "\n").prefix(limit * 2) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int(parts[0]),
                  let rssKB = Int64(parts[1]) else { continue }
            let command = parts[2...].joined(separator: " ")
            let name = (command as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            processes.append(TopProcess(pid: pid, name: name, memoryBytes: rssKB * 1024))
        }
        return Array(processes.prefix(limit))
    }
}

// MARK: - Disk

public struct DiskSnapshot: Sendable {
    public let total: Int64
    /// Honest free space, excluding APFS purgeable. This is what Sweep shows as
    /// "available" — unlike the optimistic figure macOS reports for "important
    /// usage", it doesn't pretend reclaimable space is already free.
    public let available: Int64
    /// Reclaimable (purgeable) space macOS can free on demand. Surfaced on its
    /// own, never counted as free space.
    public let purgeable: Int64

    public init(total: Int64, available: Int64, purgeable: Int64 = 0) {
        self.total = total
        self.available = available
        self.purgeable = purgeable
    }

    public var used: Int64 { max(0, total - available) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// Free space counting purgeable, i.e. what macOS advertises as "available
    /// for important usage". Used for low-disk thresholds — where reclaimable
    /// space genuinely counts — but not for the honest "available" display.
    public var opportunisticAvailable: Int64 { available + purgeable }
}

public enum DiskStats {
    public static func root() -> DiskSnapshot? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
        let total = values.volumeTotalCapacity else { return nil }
        // Optimistic figure (includes purgeable) vs. the honest, conservative
        // free-space figure. purgeable is the difference between them.
        let importantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
        let honest = values.volumeAvailableCapacity.map(Int64.init) ?? importantUsage
        let purgeable = max(0, importantUsage - honest)
        return DiskSnapshot(total: Int64(total), available: honest, purgeable: purgeable)
    }
}

// MARK: - Subprocess runner

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Mutable box for handing captured stderr back from a reader queue.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

public enum ProcessRunner {
    /// Runs an executable with arguments, capturing output. Never a shell.
    public static func run(_ path: String, _ args: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    // Read stderr on a separate queue so a child that fills the
                    // stderr buffer while we drain stdout (or vice-versa) can't
                    // deadlock — both pipes are drained concurrently.
                    let errBox = OutputBox()
                    let errQueue = DispatchQueue(label: "sweep.proc.stderr")
                    errQueue.async {
                        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    errQueue.sync {}
                    process.waitUntilExit()
                    continuation.resume(returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        stderr: String(data: errBox.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    ))
                } catch {
                    continuation.resume(returning: ProcessResult(status: 127, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }
}
