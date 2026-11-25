import Foundation

// MARK: - Homebrew

/// What `brew cleanup` would do, read from its own `--dry-run` so the button
/// can say how much it frees before anything is removed. Most of the space is
/// usually old Cellar versions, not the download cache.
public struct BrewCleanupPreview: Sendable, Equatable {
    /// Paths brew would remove (versions, downloads, logs).
    public var items: [String] = []
    /// brew's own estimate, e.g. "1.2GB".
    public var approximateFree: String?

    public var isEmpty: Bool { items.isEmpty }

    public var summary: String {
        guard !items.isEmpty else { return "Nothing to clean up." }
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return approximateFree.map { "Would remove \(count) · about \($0)" } ?? "Would remove \(count)"
    }

    /// Never let a cleanup button uninstall software or update Homebrew:
    /// `brew cleanup` runs `autoremove` by default, which removes formulae no
    /// longer recorded as a dependency — including ones the user relies on.
    public static let environment: [String: String] = [
        "HOMEBREW_NO_AUTOREMOVE": "1",
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_COLOR": "1",
        "NONINTERACTIVE": "1",
    ]

    public static let cleanupArguments = ["cleanup", "--prune=all", "-s"]

    public static func parse(_ output: String) -> BrewCleanupPreview {
        var preview = BrewCleanupPreview()
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Would remove: ") {
                let rest = text.dropFirst("Would remove: ".count)
                // "<path> (<n> files, <size>)" or "<path> (<size>)" — a 0B
                // entry frees nothing.
                if rest.hasSuffix(", 0B)") || rest.hasSuffix("(0B)") { continue }
                let path = rest.range(of: " (").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
                preview.items.append(path)
            } else if let range = text.range(of: "would free approximately ") {
                let tail = text[range.upperBound...]
                preview.approximateFree = tail.components(separatedBy: " of disk space").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return preview
    }
}

// MARK: - Docker

/// Which engine `docker` talks to. With a remote context selected (ssh://,
/// tcp://) `system df` reports and `system prune` deletes on another machine,
/// which is not this Mac's disk and not what a cleaner should touch.
public enum DockerEndpoint {
    /// Arguments that print the current context's engine address.
    public static let inspectArguments = ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]

    /// The endpoint in force: `DOCKER_HOST` wins over the context, as it does
    /// for the docker CLI itself.
    public static func effective(dockerHost: String?, contextHost: String) -> String {
        if let env = dockerHost?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty { return env }
        return contextHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// true for a local socket. An empty answer means the default context,
    /// which is the local socket.
    public static func isLocal(_ endpoint: String) -> Bool {
        let host = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty { return true }
        return host.hasPrefix("unix://") || host.hasPrefix("/")
    }
}

/// `docker system df`, with Docker's own reclaimable figure corrected where it
/// contradicts its counts. Docker Engine 29.0–29.3 reports images that back
/// running containers as 100% reclaimable (moby/moby#51775) — showing that
/// next to a "prune" button invites deleting images that are in use.
public enum DockerDiskUsage {
    public static let format = "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}\t{{.TotalCount}}\t{{.Active}}"

    public static func summary(_ output: String) -> String {
        output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 5 else { return nil }
            let (type, reclaimable) = (fields[0], fields[2])
            guard let total = Int(fields[3]), let active = Int(fields[4]) else {
                return "\(type): \(reclaimable)"
            }
            let allInUse = total > 0 && active == total && !reclaimable.hasPrefix("0B")
            let impossibleImages = type == "Images" && active > 0 && reclaimable.contains("(100%)")
            if allInUse || impossibleImages {
                return "\(type): \(active)/\(total) in use"
            }
            return "\(type): \(reclaimable)"
        }
        .joined(separator: "\n")
    }
}
