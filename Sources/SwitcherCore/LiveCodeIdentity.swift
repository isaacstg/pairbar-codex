import Foundation
import Security

/// Verifies the signed code object currently attached to a kernel-observed PID.
/// It reads no arguments, environment, profile data, Keychain item or credential.
public enum LiveCodeIdentity {
    public static func matches(_ stamp: ProcessStamp, provider: ProviderID2,
                               identity: OfficialAppIdentity) -> Bool {
        guard stamp.pid > 0, stamp.executable == identity.executable.path else { return false }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: stamp.pid)] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(provider.teamIdentifier)\" and identifier \"\(provider.bundleIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue), requirement) == errSecSuccess else {
            return false
        }
        var installed: SecStaticCode?, running: SecStaticCode?
        guard SecStaticCodeCreateWithPath(identity.app as CFURL, [], &installed) == errSecSuccess, let installed,
              SecCodeCopyStaticCode(guest, [], &running) == errSecSuccess, let running else { return false }
        var installedInfo: CFDictionary?, runningInfo: CFDictionary?
        guard SecCodeCopySigningInformation(installed, [], &installedInfo) == errSecSuccess,
              SecCodeCopySigningInformation(running, [], &runningInfo) == errSecSuccess,
              let installedHash = (installedInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let runningHash = (runningInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        return installedHash == runningHash
    }
}
