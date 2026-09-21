import Foundation

/// The identity of the object at a path, independent of the path itself.
///
/// Sweep shows a scan result, the user reads it, and only then presses Clean.
/// Minutes can pass. If the folder we measured is renamed away and a new one
/// is created at the same path in that window, deleting "by path" destroys an
/// object the user never reviewed. Comparing inode + device closes that window:
/// the thing being deleted must be the thing that was scanned.
public struct FileIdentity: Sendable, Hashable, Codable {
    public let inode: UInt64
    public let device: Int

    public init(inode: UInt64, device: Int) {
        self.inode = inode
        self.device = device
    }

    /// Reads the identity of `url`, or nil if it no longer exists.
    public static func current(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager().attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? UInt64 ?? (attributes[.systemFileNumber] as? Int).map(UInt64.init),
              let device = attributes[.systemNumber] as? Int else { return nil }
        return FileIdentity(inode: inode, device: device)
    }
}
