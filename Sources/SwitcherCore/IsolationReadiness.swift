import Foundation

/// Presentation state only. Checking never grants approval; the controller still validates
/// the exact installed fingerprint before every new isolated launch.
public enum IsolationReadiness: Equatable {
    case notChecked
    case checking
    case ready(version: String)
    case confirmationRequired(version: String, isUpdate: Bool)
    case unavailable(reason: String)

    public var requiresConfirmation: Bool {
        if case .confirmationRequired = self { return true }
        return false
    }

    public static func inspected(version: String, fingerprint: String, settings: Settings) -> IsolationReadiness {
        if settings.setupComplete && settings.approvedFingerprint == fingerprint {
            return .ready(version: version)
        }
        return .confirmationRequired(version: version, isUpdate: settings.approvedFingerprint != nil)
    }
}

public extension Settings {
    /// Renaming accounts must never approve a different installed build or complete setup.
    func renamingAccounts(current: String, second: String) throws -> Settings {
        let currentName = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondName = second.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [currentName, secondName]
        guard names.allSatisfy({ !$0.isEmpty && $0.count <= 40 &&
            $0.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.newlines.contains($0) }) }),
              currentName != secondName else {
            throw SwitcherError.message("Use two different names, each 1–40 characters long, without line breaks or control characters.")
        }
        var next = self
        next.nameA = currentName
        next.nameB = secondName
        return next
    }
}

public extension SecondaryAccountState {
    /// Pending recovery cannot be bypassed by confirming a newer installed app.
    var allowsBuildConfirmation: Bool {
        switch self {
        case .stopped, .runningVerified: return true
        case .launching, .quitting, .ownershipUncertain, .unverifiedLiveProcess: return false
        }
    }
}
