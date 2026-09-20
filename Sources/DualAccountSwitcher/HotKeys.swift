import Carbon
import Foundation
import SwitcherCore

/// Carbon owns only explicit shortcuts; there is no global keyboard event monitor.
@MainActor
final class HotKeys {
    struct Binding: Equatable {
        var targetID: String
        var keyCode: UInt32
        var modifiers: UInt32
        var legacyNumber: UInt32? = nil
    }
    private struct Chord: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
    }
    private struct Registration {
        var reference: EventHotKeyRef
        var token: UInt32
    }
    private var registrations: [Chord: Registration] = [:]
    private var bindingsByToken: [UInt32: Binding] = [:]
    private var nextToken: UInt32 = 1
    private var handler: EventHandlerRef?
    var onPress: ((UInt32) -> Void)?
    var onTargetPress: ((String) -> Void)?
    private(set) var errors: [String] = []
    private(set) var bindings: [Binding] = []

    init(registerDefaults: Bool = true) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x44414353 else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let token = id.id
            Task { @MainActor in
                guard let binding = keys.bindingsByToken[token] else { return }
                keys.onTargetPress?(binding.targetID)
                if let number = binding.legacyNumber { keys.onPress?(number) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { errors = ["shortcut-handler-unavailable (\(installed))"]; return }
        if registerDefaults {
            _ = replaceBindings([
                Binding(targetID: "current:codex", keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | cmdKey), legacyNumber: 1),
                Binding(targetID: "legacy-second", keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | cmdKey), legacyNumber: 2)
            ])
        }
    }

    /// Stage every new registration before releasing any old one. A conflict leaves
    /// the previous map and registrations intact, including swaps between targets.
    @discardableResult
    func replaceBindings(_ requested: [Binding]) -> Bool {
        guard handler != nil else { return false }
        errors = []
        var chords = Set<Chord>()
        var targets = Set<String>()
        for binding in requested {
            let chord = Chord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            guard Self.isValid(keyCode: binding.keyCode, modifiers: binding.modifiers),
                  !binding.targetID.isEmpty,
                  targets.insert(binding.targetID).inserted,
                  chords.insert(chord).inserted else {
                errors = ["shortcut-invalid-or-duplicate"]
                return false
            }
        }
        var staged: [Chord: Registration] = [:]
        for binding in requested {
            let chord = Chord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            if registrations[chord] != nil { continue }
            guard nextToken < UInt32.max else {
                for registration in staged.values { UnregisterEventHotKey(registration.reference) }
                errors = ["shortcut-registration-capacity"]
                return false
            }
            let token = nextToken
            nextToken += 1
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                EventHotKeyID(signature: 0x44414353, id: token), GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                for registration in staged.values { UnregisterEventHotKey(registration.reference) }
                errors = ["shortcut-unavailable (\(result)): \(Self.display(keyCode: binding.keyCode, modifiers: binding.modifiers))"]
                return false
            }
            staged[chord] = Registration(reference: reference, token: token)
        }
        for (chord, registration) in registrations where !chords.contains(chord) {
            UnregisterEventHotKey(registration.reference)
        }
        registrations = registrations.filter { chords.contains($0.key) }.merging(staged) { old, _ in old }
        bindingsByToken = Dictionary(uniqueKeysWithValues: requested.compactMap { binding in
            let chord = Chord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            return registrations[chord].map { ($0.token, binding) }
        })
        bindings = requested
        return true
    }

    nonisolated static func isValid(keyCode: UInt32, modifiers: UInt32) -> Bool {
        Shortcut2(keyCode: keyCode, modifiers: modifiers).isValid
    }

    nonisolated static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫",
            76: "⌤", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return symbols + (labels[keyCode] ?? "[\(keyCode)]")
    }

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
