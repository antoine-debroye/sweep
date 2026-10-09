import Foundation

/// Whether a VPN is carrying traffic right now.
///
/// Flushing DNS sends mDNSResponder a HUP; WireGuard-style clients treat that
/// as a network change and drop and rebuild the tunnel. A one-click "fix" that
/// disconnects the user's VPN is not a fix, so the flush asks first.
public enum VPNStatus: Sendable, Equatable {
    case active(String)
    case inactive
    /// A probe failed. Not evidence of "no VPN".
    case unknown

    public static func current() async -> VPNStatus {
        let nc = await ProcessRunner.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 3)
        if nc.status == 0, let name = connectedService(inNCList: nc.stdout) {
            return .active(name)
        }
        let route = await ProcessRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        let routeVerdict = defaultRouteVerdict(stdout: route.stdout, stderr: route.stderr, status: route.status)
        if routeVerdict != .inactive { return routeVerdict }
        return nc.status == 0 ? .inactive : .unknown
    }

    /// System VPN services (IKEv2, L2TP, configuration-profile VPNs) list as
    /// `* (Connected)  <uuid> … "Name" [type]` in `scutil --nc list`.
    static func connectedService(inNCList output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("* (Connected)") {
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            return quoted.count >= 3 ? String(quoted[1]) : "VPN"
        }
        return nil
    }

    /// Full-tunnel third-party clients (WireGuard, Tailscale exit nodes…) don't
    /// register with scutil; they show up as the default route leaving through
    /// a `utun` interface. A `utun` merely existing proves nothing — Private
    /// Relay and Handoff create them too — so only the default route counts.
    static func defaultRouteVerdict(stdout: String, stderr: String, status: Int32) -> VPNStatus {
        if (stdout + stderr).contains("not in table") { return .inactive }   // offline
        guard status == 0 else { return .unknown }
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let interface = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return interface.hasPrefix("utun") ? .active("tunnel on \(interface)") : .inactive
        }
        return .unknown
    }
}
