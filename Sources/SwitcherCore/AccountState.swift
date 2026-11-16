import Foundation

/// Pure, UI-independent account state used by the controller and unit tests.
public enum CurrentAccountState: Equatable {
    case stopped
    case launching
    case running(pid: Int32)
    case ambiguous(count: Int)
    case blockedBySecondaryRecovery(count: Int)

    public var displayText: String {
        switch self {
        case .stopped: return "Not running"
        case .launching: return "Launching…"
        case .running(let pid): return "Running · PID \(pid)"
        case .ambiguous(let count): return "Needs attention · \(count) default instances"
        case .blockedBySecondaryRecovery: return "Needs attention · recover Second Account first"
        }
    }

    public var isAmbiguous: Bool {
        switch self {
        case .ambiguous, .blockedBySecondaryRecovery: return true
        default: return false
        }
    }
}

public enum SecondaryAccountState: Equatable {
    case stopped
    case launching
    case runningVerified(pid: Int32)
    case quitting
    case ownershipUncertain
    case unverifiedLiveProcess

    public var displayText: String {
        switch self {
        case .stopped: return "Not running"
        case .launching: return "Launching…"
        case .runningVerified(let pid): return "Running · PID \(pid)"
        case .quitting: return "Quitting…"
        case .ownershipUncertain: return "Needs attention · ownership uncertain"
        case .unverifiedLiveProcess: return "Needs attention · unverified process"
        }
    }

    public var hasVerifiedRunningProcess: Bool {
        if case .runningVerified = self { return true }
        return false
    }

    public var needsRecovery: Bool {
        switch self {
        case .ownershipUncertain, .unverifiedLiveProcess: return true
        default: return false
        }
    }
}

/// UI/action policy derived only from state. Keeping this pure makes it hard for menus and
/// shortcuts to accidentally expose destructive actions in uncertain states.
public struct AccountCapabilities: Equatable {
    public let canOpenCurrent: Bool
    public let canOpenSecond: Bool
    public let canOpenBoth: Bool
    public let canQuitSecond: Bool
    public let canRestartSecond: Bool
    public let canRecoverSecond: Bool

    public init(current: CurrentAccountState, secondary: SecondaryAccountState,
                secondarySetupComplete: Bool, compatibilityBusy: Bool) {
        switch current {
        case .stopped, .running:
            canOpenCurrent = true
        case .launching, .ambiguous, .blockedBySecondaryRecovery:
            canOpenCurrent = false
        }

        switch secondary {
        case .stopped, .runningVerified:
            canOpenSecond = secondarySetupComplete && !compatibilityBusy
        case .launching, .quitting, .ownershipUncertain, .unverifiedLiveProcess:
            canOpenSecond = false
        }

        canQuitSecond = secondary.hasVerifiedRunningProcess
        canRestartSecond = secondary.hasVerifiedRunningProcess && secondarySetupComplete && !compatibilityBusy
        canRecoverSecond = secondary.needsRecovery
        canOpenBoth = canOpenCurrent && canOpenSecond
    }
}

/// Resolves the default/current account without inspecting credentials, argv, or process environments.
/// The only process excluded is a secondary PID whose ownership was independently proven.
public enum AccountStateResolver {
    public static func currentCandidatePIDs(officialPIDs: [Int32], verifiedSecondaryPID: Int32?) -> [Int32] {
        let unique = Set(officialPIDs.filter { $0 > 0 })
        return unique.filter { $0 != verifiedSecondaryPID }.sorted()
    }

    public static func current(officialPIDs: [Int32], verifiedSecondaryPID: Int32?,
                               secondaryOwnershipUncertain: Bool = false,
                               launching: Bool = false) -> CurrentAccountState {
        let candidates = currentCandidatePIDs(officialPIDs: officialPIDs, verifiedSecondaryPID: verifiedSecondaryPID)
        // If B may exist but cannot be proven, no remaining official process can safely be
        // classified as Current. Even zero processes stays blocked so recovery can run while
        // the system is in the one state that conclusively proves no orphan is alive.
        if secondaryOwnershipUncertain {
            return .blockedBySecondaryRecovery(count: candidates.count)
        }
        if candidates.count == 1 { return .running(pid: candidates[0]) }
        if candidates.count > 1 { return .ambiguous(count: candidates.count) }
        return launching ? .launching : .stopped
    }

    public static func secondary(receipt: LaunchReceipt?, currentStamp: ProcessStamp?, paths: ProfilePaths,
                                 uid: UInt32, pending: Bool, launching: Bool, quitting: Bool,
                                 recordedPIDIsLive: Bool) -> SecondaryAccountState {
        if pending { return .ownershipUncertain }
        if quitting { return .quitting }
        if launching { return .launching }
        guard let receipt else { return .stopped }
        if receipt.owns(currentStamp, paths: paths, uid: uid) { return .runningVerified(pid: receipt.stamp.pid) }
        return recordedPIDIsLive ? .unverifiedLiveProcess : .stopped
    }
}

/// Migration is intentionally metadata-only. It never deletes or reads profile contents.
public enum MetadataMigration {
    public static func keepSecondaryReceipts(_ receipts: [LaunchReceipt]) throws -> [LaunchReceipt] {
        let secondary = receipts.filter { $0.profile == .b }
        guard secondary.count <= 1 else { throw SwitcherError.message("Invalid metadata: multiple Second Account receipts.") }
        return secondary
    }

    public static func keepSecondaryPending(_ pending: [ProfileID]) -> [ProfileID] {
        pending.contains(.b) ? [.b] : []
    }
}
