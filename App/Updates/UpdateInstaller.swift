import Foundation
import AppKit
import CryptoKit
import SweepCore

/// The mechanics of applying an update: authenticated download of the release
/// `.zip`, SHA-256 verification, unzip, Developer ID signature check, and an
/// in-place self-replace + relaunch.
/// Stateless; `UpdateChecker` drives it and owns the UI state. The heavy,
/// blocking steps (`unzip`, `sha256`) are synchronous and are meant to be called
/// off the main actor via `Task.detached`.
enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case badResponse(Int)
        case notWritable
        case unzipFailed
        case appNotFound
        case checksumMismatch
        case missingChecksum
        case untrustedSignature

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): "The download failed (HTTP \(code))."
            case .notWritable: "Sweep can't update itself from its current location. Reinstall it from the DMG into Applications, then updates will work."
            case .unzipFailed: "The downloaded update couldn't be unpacked."
            case .appNotFound: "The downloaded update didn't contain Sweep.app."
            case .checksumMismatch: "The downloaded update failed its integrity check and was discarded."
            case .missingChecksum: "This release has no checksum in its notes, so Sweep won't install it."
            case .untrustedSignature: "The downloaded update isn't signed by Sweep's developer, so it was discarded."
            }
        }
    }

    /// Strips the `Authorization` header when GitHub redirects the asset download
    /// to a different host (codeload / S3). Required for private-repo downloads —
    /// the signed redirect URL rejects the header — and prevents the token from
    /// ever being sent to the storage host. Stateless, hence safe to share.
    private final class RedirectStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            var forwarded = request
            let originalHost = task.originalRequest?.url?.host
            if request.url?.host != originalHost {
                forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(forwarded)
        }
    }

    /// Downloads the release zip via the GitHub asset API (works for private
    /// repos), returning a stable temp file URL the caller is responsible for.
    static func downloadZip(assetURL: URL, token: String) async throws -> URL {
        var request = URLRequest(url: assetURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Sweep-Updater", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral, delegate: RedirectStripper(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.badResponse(http.statusCode)
        }
        // download(for:) may reclaim its temp file; move it somewhere stable.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sweep-update-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Lowercase hex SHA-256 of a file, streamed so large archives aren't held in memory.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips the archive and returns the URL of the `Sweep.app` inside it.
    static func unzip(_ zipURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sweep-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, dir.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError.unzipFailed }

        // The zip was created with --keepParent, so Sweep.app sits at the top level.
        let direct = dir.appendingPathComponent("Sweep.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Fallback: find the first *.app anywhere in the extracted tree.
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil),
           let found = enumerator.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "app" }) {
            return found
        }
        throw InstallError.appNotFound
    }

    /// Throws unless `appURL` is a real directory (not a symlink to somewhere
    /// else) whose whole bundle is validly signed by our Developer ID team.
    static func verifySignature(of appURL: URL) throws {
        let values = try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink == false, values?.isDirectory == true,
              case .success = UpdateSignature.verify(appAt: appURL) else {
            throw InstallError.untrustedSignature
        }
    }

    /// Whether the running bundle can be replaced in place: it must live in a
    /// writable directory and not be a dev/DerivedData build.
    static func canInstall(replacing bundleURL: URL) -> Bool {
        let path = bundleURL.path
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return false }
        let parent = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    /// Reveals a file in Finder — used as the fallback when self-install isn't possible.
    @MainActor
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Replaces the running app with `newApp` and relaunches it. Spawns a detached
    /// shell script that waits for this process to exit, swaps the bundle (staging
    /// first so a failure never leaves the user with no app), clears quarantine, and
    /// reopens — then terminates this process. Must run on the main actor.
    @MainActor
    static func installAndRelaunch(newApp: URL, replacing dest: URL) throws {
        guard canInstall(replacing: dest) else { throw InstallError.notWritable }

        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-update-\(UUID().uuidString).sh")

        let script = """
        #!/bin/bash
        trap '' HUP
        PID="\(pid)"
        NEW="\(newApp.path)"
        DEST="\(dest.path)"
        STAGING="${DEST}.new"

        # Wait (up to ~30s) for Sweep to quit before touching its bundle.
        for _ in $(seq 1 150); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done

        rm -rf "$STAGING"
        if ! /usr/bin/ditto "$NEW" "$STAGING"; then
            open "$DEST"    # copy failed: relaunch the existing version untouched
            exit 1
        fi
        rm -rf "$DEST"
        mv "$STAGING" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        open "$DEST"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()   // detached child; survives our termination

        Lifecycle.terminating("self-update relaunch (installing \(newApp.lastPathComponent) over \(dest.path))")
        NSApp.terminate(nil)
    }
}
