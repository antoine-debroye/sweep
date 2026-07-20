import Foundation
import Observation
import ServiceManagement

/// Front door for anything that needs root: prefers the SMAppService helper
/// daemon (one-time approval, then silent), falls back to an osascript
/// administrator prompt when the helper isn't available (e.g. ad-hoc signing).
@MainActor
@Observable
public final class PrivilegeBroker {
    public enum HelperState: String, Sendable {
        case enabled
        case requiresApproval
        case notInstalled
        case unavailable

        public var label: String {
            switch self {
            case .enabled: "Installed & active"
            case .requiresApproval: "Waiting for approval in System Settings"
            case .notInstalled: "Not installed"
            case .unavailable: "Unavailable"
            }
        }
    }

    public private(set) var helperState: HelperState = .notInstalled
    public private(set) var lastError: String?

    /// Guards `repairHelperOnce()` so a broken helper is re-registered at most
    /// once per app session.
    private var didAttemptHelperRepair = false

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: SweepHelperConstants.daemonPlistName)
    }

    public init() {
        refreshHelperState()
    }

    public func refreshHelperState() {
        switch daemonService.status {
        case .enabled: helperState = .enabled
        case .requiresApproval: helperState = .requiresApproval
        case .notRegistered: helperState = .notInstalled
        case .notFound: helperState = .unavailable
        @unknown default: helperState = .unavailable
        }
    }

    public func installHelper() {
        do {
            try daemonService.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshHelperState()
        if helperState == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    public func uninstallHelper() {
        do {
            try daemonService.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshHelperState()
    }

    // MARK: - Operations

    /// Runs `body` through the privileged helper, or returns nil if the helper
    /// can't serve it (caller then falls back to the osascript admin prompt).
    ///
    /// launchd keeps a helper process alive across app updates — its `runs`
    /// count never increments — so a self-update leaves the *old* helper binary
    /// serving the mach endpoint. If a call fails we therefore re-register the
    /// daemon once per session, which makes launchd exec the current binary,
    /// then retry before giving up.
    private func viaHelper(
        _ body: @escaping @Sendable (SweepHelperProtocol, @escaping @Sendable (Int32, String) -> Void) -> Void
    ) async -> String? {
        guard helperState == .enabled else { return nil }
        do {
            return try await xpcCall(body)
        } catch {
            NSLog("Sweep: privileged helper call failed (\(error.localizedDescription))")
        }
        guard repairHelperOnce() else { return nil }
        return try? await xpcCall(body)
    }

    /// Re-registers the daemon so launchd reloads the current helper binary.
    /// At most once per session, so a genuinely broken helper can't loop.
    private func repairHelperOnce() -> Bool {
        guard !didAttemptHelperRepair else { return false }
        didAttemptHelperRepair = true
        NSLog("Sweep: re-registering the privileged helper (stale daemon suspected)")
        do {
            try? daemonService.unregister()
            try daemonService.register()
        } catch {
            lastError = error.localizedDescription
            refreshHelperState()
            return false
        }
        refreshHelperState()
        return helperState == .enabled
    }

    public func purgeMemory() async throws -> String {
        if let output = await viaHelper({ helper, done in helper.purgeMemory(reply: done) }) {
            return output
        }
        return try await Self.runAsAdmin(
            command: "/usr/sbin/purge",
            explanation: "Sweep needs administrator access to flush inactive memory."
        )
    }

    public func removeSystemPaths(_ paths: [String]) async throws -> String {
        let valid = paths.filter { PrivilegedPathPolicy.isAllowed($0) }
        guard !valid.isEmpty else { throw BrokerError.nothingToDo }
        if let output = await viaHelper({ helper, done in helper.removePaths(valid, reply: done) }) {
            return output
        }
        let quoted = valid.map { Self.shellQuote($0) }.joined(separator: " ")
        return try await Self.runAsAdmin(
            command: "/bin/rm -rf -- \(quoted)",
            explanation: "Sweep needs administrator access to remove system caches and logs."
        )
    }

    public func runMaintenance(_ task: MaintenanceTask) async throws -> String {
        if let output = await viaHelper({ helper, done in helper.runMaintenance(task.rawValue, reply: done) }) {
            return output
        }
        let cmd = task.commandLine
        var command = ([cmd.path] + cmd.args).map { Self.shellQuote($0) }.joined(separator: " ")
        if task == .flushDNS {
            command += " && /usr/bin/killall -HUP mDNSResponder"
        }
        return try await Self.runAsAdmin(
            command: command,
            explanation: "Sweep needs administrator access to run this maintenance task."
        )
    }

    // MARK: - XPC plumbing

    private func xpcCall(
        _ body: @escaping @Sendable (SweepHelperProtocol, @escaping @Sendable (Int32, String) -> Void) -> Void
    ) async throws -> String {
        let connection = NSXPCConnection(machServiceName: SweepHelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SweepHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            // Guard against a helper that accepts the message and then never
            // replies while the connection stays alive: NSXPC won't time out a
            // pending reply on its own, so without this the await hangs forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                if resumed.claim() { continuation.resume(throwing: BrokerError.timedOut) }
            }
            // @Sendable is required: NSXPC invokes this handler on its own
            // private connection queue, not the main actor. Without it the
            // closure inherits @MainActor isolation from this method and the
            // Swift 6 runtime traps (dispatch_assert_queue) when it runs off
            // the main thread — e.g. when the helper replies with an error.
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                if resumed.claim() { continuation.resume(throwing: error) }
            }) as? SweepHelperProtocol else {
                if resumed.claim() { continuation.resume(throwing: BrokerError.helperUnreachable) }
                return
            }
            body(proxy) { status, output in
                guard resumed.claim() else { return }
                if status == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BrokerError.helperFailed(output))
                }
            }
        }
    }

    public func helperVersion() async -> String? {
        guard helperState == .enabled else { return nil }
        return try? await xpcCall { helper, done in
            helper.version { version in done(0, version) }
        }
    }

    // MARK: - osascript fallback

    nonisolated static func runAsAdmin(command: String, explanation: String) async throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = explanation
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        let result = await ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            if result.stderr.contains("-128") { throw BrokerError.userCancelled }
            throw BrokerError.helperFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public enum BrokerError: LocalizedError {
        case helperUnreachable
        case helperFailed(String)
        case userCancelled
        case nothingToDo
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .helperUnreachable: "The privileged helper could not be reached."
            case .helperFailed(let output): output.isEmpty ? "The operation failed." : output
            case .userCancelled: "Cancelled."
            case .nothingToDo: "Nothing to do."
            case .timedOut: "The privileged helper did not respond in time."
            }
        }
    }
}

/// Ensures a continuation is resumed exactly once across the reply and the
/// XPC error handler.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

extension PrivilegeBroker: PrivilegedRemoving {
    public nonisolated func removePrivileged(paths: [String]) async throws -> String {
        try await removeSystemPaths(paths)
    }
}
