import Foundation

/// Inputs must come from a single official-app enumeration and identity observations. This resolver
/// never adopts a process, changes metadata, reads another process's arguments or infers an account.
public enum DynamicStateResolver {
    public static func resolve(provider: ProviderID2, records: [ProfileRecord2], root: URL,
                               officialPIDs: [Int32], observations: [Int32: ProcessObservation2], uid: UInt32,
                               launching: Set<ManagedProfileID> = [], quitting: Set<ManagedProfileID> = [],
                               currentLaunching: Bool = false, metadataUncertain: Bool = false) -> ProviderState2 {
        let relevant = records.filter { $0.provider == provider }
        var uncertain = metadataUncertain
        var invalid = Set<ManagedProfileID>()
        var seenIDs = Set<ManagedProfileID>()
        var byPID: [Int32: ManagedProfileID] = [:]
        var byPath: [String: ManagedProfileID] = [:]
        // Cross-provider duplicates also invalidate ownership. No receipt wins by array order.
        for record in records {
            if !seenIDs.insert(record.id).inserted { invalid.insert(record.id) }
            if !record.archived {
                let path = Paths2(root: root, provider: record.provider, storage: record.storage).base.path
                if let previous = byPath[path] { invalid.formUnion([previous, record.id]) }
                byPath[path] = record.id
            }
            if let receipt = record.receipt {
                if let previous = byPID[receipt.stamp.pid] { invalid.formUnion([previous, record.id]) }
                byPID[receipt.stamp.pid] = record.id
            }
        }

        let official = Set(officialPIDs)
        if official.contains(where: { $0 <= 0 }) { uncertain = true }
        var states: [ManagedProfileID: ManagedState2] = [:]
        var provenPIDs = Set<Int32>()
        for record in relevant {
            let paths = Paths2(root: root, provider: provider, storage: record.storage)
            if invalid.contains(record.id) || record.schemaVersion != 1 ||
                (record.storage == .legacySecond && (provider != .codex || record.id != .legacySecond)) {
                states[record.id] = .ownershipUncertain; uncertain = true; continue
            }
            if record.archived {
                if record.receipt != nil || record.pending != nil {
                    states[record.id] = .ownershipUncertain; uncertain = true
                } else { states[record.id] = .archived }
                continue
            }
            if record.pending != nil {
                states[record.id] = launching.contains(record.id) ? .launching : .ownershipUncertain
                uncertain = true; continue
            }
            guard let receipt = record.receipt else {
                // In-flight UI state is not a substitute for the durable pending intent.
                if launching.contains(record.id) || quitting.contains(record.id) {
                    states[record.id] = .ownershipUncertain; uncertain = true
                } else { states[record.id] = .stopped }
                continue
            }
            switch observations[receipt.stamp.pid] ?? .unreadable {
            case .absent:
                if official.contains(receipt.stamp.pid) {
                    states[record.id] = .unverifiedLiveProcess; uncertain = true
                } else { states[record.id] = .stopped }
            case .unreadable:
                states[record.id] = .unverifiedLiveProcess; uncertain = true
            case .verified(let stamp):
                if official.contains(stamp.pid), receipt.owns(stamp, profile: record, paths: paths, uid: uid) {
                    provenPIDs.insert(stamp.pid)
                    states[record.id] = quitting.contains(record.id) ? .quitting : .runningVerified(pid: stamp.pid)
                } else {
                    states[record.id] = .unverifiedLiveProcess; uncertain = true
                }
            }
        }

        // Official identity verification belongs to the runtime; unreadable identities still block
        // Current even when they are not mentioned by a stored receipt.
        for pid in official {
            guard case .verified(let stamp) = observations[pid], stamp.pid == pid, stamp.uid == uid else {
                uncertain = true; continue
            }
        }
        let candidates = official.subtracting(provenPIDs).sorted()
        let current: CurrentState2
        if uncertain { current = .blockedByRecovery }
        else if candidates.count > 1 { current = .ambiguous(count: candidates.count) }
        else if let pid = candidates.first { current = .running(pid: pid) }
        else { current = currentLaunching ? .launching : .stopped }
        return ProviderState2(current: current, profiles: states, needsRecovery: uncertain)
    }
}
