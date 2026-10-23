import Foundation
import Security

/// Verifies that a downloaded update is a genuine Sweep build before it may
/// replace the running app.
///
/// The SHA-256 in the release notes comes from the same GitHub release as the
/// zip, so it only proves the download wasn't corrupted. Anyone able to publish
/// a release (for example with a leaked token) could ship a matching checksum.
/// A valid Developer ID signature from our team can't be forged that way, so it
/// is the check that actually decides whether an update is trusted.
public enum UpdateSignature {
    public static let bundleIdentifier = "com.debroye.sweep"

    /// The code-signing requirement an update must meet: Sweep's bundle ID,
    /// signed through Apple's Developer ID chain, by our team.
    /// Same identity the privileged helper accepts from its clients.
    public static func requirement(
        teamID: String = SweepHelperConstants.teamIdentifier,
        bundleID: String = bundleIdentifier
    ) -> String {
        """
        identifier "\(bundleID)" \
        and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case badRequirement
        case invalid(OSStatus)
    }

    /// Checks the whole bundle, nested code included (the embedded framework and
    /// the privileged helper), so a single swapped binary also fails.
    public static func verify(
        appAt url: URL,
        teamID: String = SweepHelperConstants.teamIdentifier,
        bundleID: String = bundleIdentifier
    ) -> Result<Void, Failure> {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return .failure(.unreadable) }

        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement(teamID: teamID, bundleID: bundleID) as CFString,
                                             [], &secRequirement) == errSecSuccess,
              let secRequirement else { return .failure(.badRequirement) }

        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, secRequirement, nil)
        return status == errSecSuccess ? .success(()) : .failure(.invalid(status))
    }
}
