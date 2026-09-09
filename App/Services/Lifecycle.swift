import AppKit
import os

/// Process lifecycle breadcrumbs. Sweep once quit and relaunched on its own
/// with no crash report and nothing in the log; every termination path now
/// leaves a line here so the next occurrence is diagnosable with:
///   log show --predicate 'subsystem == "com.debroye.sweep"' --last 1h
@MainActor
enum Lifecycle {
    static let log = Logger(subsystem: "com.debroye.sweep", category: "lifecycle")

    private static var signalSources: [DispatchSourceSignal] = []

    static func launched() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let args = ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")
        log.notice("launched v\(version, privacy: .public) (\(build, privacy: .public)) pid \(getpid()) ppid \(getppid()) bundle \(Bundle.main.bundlePath, privacy: .public) args [\(args, privacy: .public)]")
        installSignalHandlers()
        NSSetUncaughtExceptionHandler { exception in
            let log = Logger(subsystem: "com.debroye.sweep", category: "lifecycle")
            log.fault("uncaught exception \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)\n\(exception.callStackSymbols.joined(separator: "\n"), privacy: .public)")
        }
    }

    /// Records who asked us to quit and why, right before the app goes.
    static func terminating(_ reason: String) {
        log.notice("terminating: \(reason, privacy: .public)")
    }

    /// SIGTERM/SIGINT/SIGHUP would otherwise kill the process silently and
    /// without `applicationWillTerminate`. Log them, then quit gracefully.
    private static func installSignalHandlers() {
        for (sig, name) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT"), (SIGHUP, "SIGHUP")] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Logger(subsystem: "com.debroye.sweep", category: "lifecycle")
                    .error("received \(name, privacy: .public) — quitting gracefully")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
