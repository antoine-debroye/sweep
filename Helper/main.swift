import Foundation

/// Privileged helper daemon for Sweep.
///
/// Runs as root via SMAppService + launchd. Exposes a deliberately narrow XPC
/// surface: purge memory, delete allow-listed system-junk paths, and run a
/// fixed set of maintenance commands. It never executes caller-supplied
/// command strings.

final class HelperService: NSObject, SweepHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(SweepHelperConstants.version)
    }

    func purgeMemory(reply: @escaping @Sendable (Int32, String) -> Void) {
        let purgePath = ["/usr/sbin/purge", "/usr/bin/purge"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let purgePath else {
            reply(1, "purge binary not found")
            return
        }
        let result = HelperService.run(purgePath, [])
        reply(result.status, result.output)
    }

    func removePaths(_ paths: [String], reply: @escaping @Sendable (Int32, String) -> Void) {
        var removed = 0
        var failures: [String] = []
        let fm = FileManager()
        for path in paths {
            guard PrivilegedPathPolicy.isAllowedResolvingSymlinks(path) else {
                failures.append("rejected (not allow-listed): \(path)")
                continue
            }
            do {
                try fm.removeItem(atPath: path)
                removed += 1
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        let summary = "removed \(removed)/\(paths.count)"
            + (failures.isEmpty ? "" : "; " + failures.joined(separator: "; "))
        reply(failures.isEmpty ? 0 : 2, summary)
    }

    func runMaintenance(_ taskID: String, reply: @escaping @Sendable (Int32, String) -> Void) {
        guard let task = MaintenanceTask(rawValue: taskID) else {
            reply(1, "unknown maintenance task: \(taskID)")
            return
        }
        let cmd = task.commandLine
        var result = HelperService.run(cmd.path, cmd.args)
        if task == .flushDNS, result.status == 0 {
            let hup = HelperService.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            result = (hup.status, result.output + "\n" + hup.output)
        }
        reply(result.status, result.output)
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            // Drain the pipe to EOF BEFORE waiting: reading first keeps the
            // buffer from filling and deadlocking a child that writes a lot of
            // output. EOF arrives when the child exits and closes the pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (1, "failed to launch \(path): \(error.localizedDescription)")
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Best-effort caller check. With ad-hoc signing there is no stable team
        // identifier to pin, so we verify the client's signing identifier. When
        // the app moves to Developer ID, tighten this with a team requirement.
        if !HelperDelegate.clientIsTrusted(connection) {
            NSLog("Sweep helper: rejecting connection from untrusted client")
            return false
        }
        let interface = NSXPCInterface(with: SweepHelperProtocol.self)
        connection.exportedInterface = interface
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }

    private static func clientIsTrusted(_ connection: NSXPCConnection) -> Bool {
        var token = connection.auditToken
        let attributes = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout.size(ofValue: token))] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        let requirementString = "identifier \"com.debroye.sweep\"" as CFString
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

// NSXPCConnection.auditToken is not exposed publicly; bridge it via KVC.
private extension NSXPCConnection {
    var auditToken: audit_token_t {
        var token = audit_token_t()
        if let value = self.value(forKey: "auditToken") as? NSData, value.length == MemoryLayout<audit_token_t>.size {
            value.getBytes(&token, length: MemoryLayout<audit_token_t>.size)
        }
        return token
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: SweepHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
NSLog("Sweep helper \(SweepHelperConstants.version) listening on \(SweepHelperConstants.machServiceName)")
RunLoop.main.run()
