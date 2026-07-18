import Foundation
import Security

/// Stores the user's GitHub access token in the login Keychain so the updater
/// can read a **private** repo's releases. The token is entered by the user (a
/// `SecureField` in Settings) or imported from their `gh` CLI login — it is never
/// written to `UserDefaults`, never logged, and never leaves the machine except
/// as an `Authorization` header to `api.github.com`.
enum GitHubTokenStore {
    private static let service = "com.debroye.sweep.updater"
    private static let account = "github-token"

    /// The stored token, or `nil` if none has been saved.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// True if a non-empty token is stored (used to gate the auto-check).
    static var hasToken: Bool { load() != nil }

    /// Saves (or replaces) the token. An empty/whitespace value deletes it.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Upsert: update if present, otherwise add.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(base.merging(update) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Convenience: pull the token from an existing `gh` CLI login (`gh auth token`)
    /// so the user doesn't have to hand-create a PAT. Returns `nil` if `gh` isn't
    /// installed or isn't logged in. GUI apps don't inherit the shell `PATH`, so we
    /// probe the usual Homebrew / system locations directly.
    static func importFromGitHubCLI() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }
}
