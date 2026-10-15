import Foundation
import Security

/// Whether the appex `pluginkit` named is really 1Password's, decided from its code signature
/// before anything of it is loaded or granted.
///
/// **A name proves nothing.** Any developer can register a Safari extension under any bundle
/// identifier, and the one picked here is given every permission it asks for on every site. So
/// the appex has to satisfy a code requirement that only 1Password's own signing can: Apple's
/// anchor, 1Password's exact identifier, and either the Mac App Store's signature or a Developer
/// ID certificate issued to 1Password's team.
///
/// The requirement is 1Password's own designated requirement, read with `codesign -d -r-` from
/// 1Password for Safari 8.12.41 as the App Store installs it, which is signed "Apple Mac OS
/// Application Signing" with team `2BUA8C4S2C`. Its App Store branch names no team, because Apple
/// is the signer there, so the team the signature carries is checked as well: the code directory
/// that holds it is covered by Apple's signature and cannot be rewritten without breaking it.
///
/// Checked once, as the extension is found. Somebody able to replace the appex between this and
/// WebKit reading it could already write to `/Applications`, and has no need of Bloom.
extension BrowserPasswordManager {
    /// The one appex this loads.
    public static let extensionIdentifier = "com.1password.safari.extension"

    /// AgileBits, which signs every 1Password build.
    public static let signingTeam = "2BUA8C4S2C"

    /// What the appex's signature must satisfy, in the language `csreq` reads.
    public static let codeRequirement =
        "identifier \"\(extensionIdentifier)\" and anchor apple generic and ("
            // The Mac App Store, which is how 1Password for Safari is distributed.
            + "certificate leaf[field.1.2.840.113635.100.6.1.9] or "
            // Developer ID, issued to 1Password's own team.
            + "certificate 1[field.1.2.840.113635.100.6.2.6] and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] and "
            + "certificate leaf[subject.OU] = \"\(signingTeam)\")"

    /// What checking a signature came to.
    public enum Signature: Equatable, Sendable {
        case trusted
        /// Why not, as the end of the sentence Settings shows after "would not load:".
        case untrusted(String)
    }

    /// Whether the bundle at `url` is signed as 1Password's appex. Hashes every file in it, so it
    /// is slow enough to keep off the main actor. See `locate()`.
    public static func signature(ofBundleAt url: URL) -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return .untrusted("its code signature could not be read.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return .untrusted("Bloom could not build the check for 1Password's signature.")
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let said = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return .untrusted("it is not signed by 1Password (\(said)).")
        }
        return signature(team: teamIdentifier(ofBundleAt: url))
    }

    /// The team half of the check, apart from reading it, so it can be tested.
    public static func signature(team: String?) -> Signature {
        guard team == signingTeam else {
            return .untrusted("it is signed by team \(team ?? "none") rather than 1Password's.")
        }
        return .trusted
    }

    /// The signing team of the bundle at `url`, read from its code signature, or nil.
    public static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
