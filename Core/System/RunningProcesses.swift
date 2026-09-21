import Foundation
import Darwin

/// Executable paths of the processes currently running.
///
/// `NSWorkspace.runningApplications` is not enough: it only knows about
/// processes registered as applications. A background agent that launchd spawns
/// straight out of an `.app` bundle — `figma_agent` running from
/// `~/Library/Application Support/Figma/FigmaAgent.app` long after Figma was
/// uninstalled — never appears there, so a cleaner relying on it would happily
/// delete the folder out from under a live process.
public enum RunningProcesses {

    /// Best-effort set of absolute executable paths. Processes belonging to
    /// other users are skipped silently (`proc_pidpath` needs privileges for
    /// those), which is fine: the folders Sweep offers are all in this user's
    /// home.
    public static func executablePaths() -> Set<String> {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Headroom, because processes can appear between the two calls.
        capacity += 128
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let stride = Int32(MemoryLayout<pid_t>.size)
        let written = proc_listallpids(&pids, capacity * stride)
        guard written > 0 else { return [] }

        var paths = Set<String>()
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not exported to Swift.
        let bufferSize = 4 * Int(MAXPATHLEN)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for pid in pids.prefix(Int(written)) where pid > 0 {
            let length = buffer.withUnsafeMutableBytes { raw in
                proc_pidpath(pid, raw.baseAddress, UInt32(bufferSize))
            }
            guard length > 0 else { continue }
            paths.insert(String(decoding: buffer[0..<Int(length)], as: UTF8.self))
        }
        return paths
    }
}
