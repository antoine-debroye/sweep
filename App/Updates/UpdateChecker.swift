import Foundation
import Observation
import SweepCore

// MARK: - GitHub API models

/// A release asset. `url` is the GitHub *API* asset URL — downloading it with
/// `Accept: application/octet-stream` works for private repos (the browser URL
/// does not without extra handling).
struct GitHubAsset: Codable, Equatable, Sendable {
    let name: String
    let url: URL
    let size: Int
}

private struct RawRelease: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

/// A parsed release ready for the UI/installer.
struct UpdateRelease: Equatable, Sendable {
    let tag: String
    let displayName: String
    let notes: String
    let zipAsset: GitHubAsset?
    /// Expected SHA-256 of the zip, parsed from a `zip-sha256: <hex>` line in the
    /// release notes (written by `Scripts/release.sh`). Required: a release
    /// without it is reported as an error and never installed.
    let expectedSHA256: String?
}

// MARK: - Errors

enum UpdaterError: LocalizedError {
    case noToken
    case unauthorized
    case noReleaseFound
    case http(Int)
    case network
    case unreadableVersion
    case noDownloadableAsset

    var errorDescription: String? {
        switch self {
        case .noToken: "Add a GitHub access token below to check for updates."
        case .unauthorized: "GitHub rejected the token. Check it has read access to the sweep repo."
        case .noReleaseFound: "No releases found yet."
        case .http(let code): "GitHub returned an error (HTTP \(code))."
        case .network: "Couldn't reach GitHub. Check your connection."
        case .unreadableVersion: "Couldn't read the release version number."
        case .noDownloadableAsset: "The latest release has no installable .zip asset."
        }
    }
}

// MARK: - UpdateChecker

/// Checks the private `antoine-debroye/sweep` repo for a newer release and, on
/// request, applies it. `@Observable` (unlike `AutoTrimScheduler`) because the UI
/// reflects a multi-state flow; exposed as `AppModel.updater`.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    /// The running app's marketing version, read once from the bundle.
    let currentVersion: String
    private let currentSemVer: SemanticVersion?
    private let repo = "antoine-debroye/sweep"
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.currentVersion = raw
        self.currentSemVer = SemanticVersion(raw)
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    var availableRelease: UpdateRelease? {
        if case .available(let r) = state { return r }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: Check

    /// Queries the latest release and compares versions. `manual` surfaces errors
    /// (e.g. missing token) in the UI; the automatic launch check stays quiet.
    func check(manual: Bool) async {
        guard let token = GitHubTokenStore.load() else {
            if manual { state = .failed(UpdaterError.noToken.localizedDescription) }
            return
        }
        state = .checking
        do {
            let release = try await fetchLatestRelease(token: token)
            settings.lastUpdateCheck = Date()

            guard let current = currentSemVer, let latest = SemanticVersion(release.tag) else {
                throw UpdaterError.unreadableVersion
            }
            if latest > current {
                guard release.zipAsset != nil else { throw UpdaterError.noDownloadableAsset }
                guard release.expectedSHA256 != nil else { throw UpdateInstaller.InstallError.missingChecksum }
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(friendly(error))
        }
    }

    // MARK: Install

    /// Downloads, verifies, and applies the available update, then relaunches.
    func installUpdate() async {
        guard case .available(let release) = state,
              let asset = release.zipAsset,
              let token = GitHubTokenStore.load() else { return }
        do {
            guard let expected = release.expectedSHA256 else {
                throw UpdateInstaller.InstallError.missingChecksum
            }
            state = .downloading
            let zipURL = try await UpdateInstaller.downloadZip(assetURL: asset.url, token: token)

            let actual = try await Task.detached { try UpdateInstaller.sha256(ofFileAt: zipURL) }.value
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: zipURL)
                throw UpdateInstaller.InstallError.checksumMismatch
            }

            state = .installing
            let appURL = try await Task.detached { try UpdateInstaller.unzip(zipURL) }.value
            // The checksum only proves the download matches the release; the
            // signature proves the release was built by us. Never skip it.
            do {
                try await Task.detached { try UpdateInstaller.verifySignature(of: appURL) }.value
            } catch {
                try? FileManager.default.removeItem(at: appURL)
                try? FileManager.default.removeItem(at: zipURL)
                throw error
            }
            let current = Bundle.main.bundleURL

            guard UpdateInstaller.canInstall(replacing: current) else {
                UpdateInstaller.revealInFinder(appURL)
                throw UpdateInstaller.InstallError.notWritable
            }
            // Replaces the bundle and relaunches; this process terminates here.
            try UpdateInstaller.installAndRelaunch(newApp: appURL, replacing: current)
        } catch {
            state = .failed(friendly(error))
        }
    }

    /// Dismiss a terminal (upToDate/failed) message back to idle.
    func reset() { state = .idle }

    // MARK: - Networking

    private func fetchLatestRelease(token: String) async throws -> UpdateRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdaterError.network
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Sweep-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdaterError.network
        }
        guard let http = response as? HTTPURLResponse else { throw UpdaterError.network }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UpdaterError.unauthorized
        case 404: throw UpdaterError.noReleaseFound
        default: throw UpdaterError.http(http.statusCode)
        }

        let raw = try JSONDecoder().decode(RawRelease.self, from: data)
        let zip = raw.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return UpdateRelease(
            tag: raw.tagName,
            displayName: raw.name?.isEmpty == false ? raw.name! : raw.tagName,
            notes: raw.body ?? "",
            zipAsset: zip,
            expectedSHA256: ReleaseNotes.parseZipSHA256(from: raw.body ?? "")
        )
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? UpdaterError { return e.localizedDescription }
        if let e = error as? UpdateInstaller.InstallError { return e.localizedDescription }
        return "Update failed: \(error.localizedDescription)"
    }
}
