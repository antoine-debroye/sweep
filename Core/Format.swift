import Foundation

public extension Int64 {
    /// "1.24 GB" style, file-size (decimal) semantics — for disk space.
    var sweepBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    /// Binary (1024-based) semantics — for RAM, matching Activity Monitor.
    var sweepMemory: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .memory)
    }
}

public extension Date {
    var sweepRelative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var sweepAgeDays: Int {
        max(0, Int(Date().timeIntervalSince(self) / 86_400))
    }
}
