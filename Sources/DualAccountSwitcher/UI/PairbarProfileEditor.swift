import AppKit
import Carbon
import SwiftUI

struct PairbarProfileEditor: View {
    @ObservedObject var model: PairbarPanelModel
    let row: PairbarProfileRow?
    @State private var draft: PairbarProfileDraft

    init(model: PairbarPanelModel, row: PairbarProfileRow?) {
        self.model = model
        self.row = row
        _draft = State(initialValue: row.map {
            PairbarProfileDraft(providerID: $0.providerID, name: $0.name, favorite: $0.favorite, shortcut: $0.shortcut, openAtLogin: $0.openAtLogin)
        } ?? PairbarProfileDraft(providerID: model.providers.first { $0.canCreate }?.id ?? "codex"))
    }
    private func t(_ english: String, _ spanish: String) -> String { model.text(english, spanish) }
    private var normalizedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? {
        if normalizedName.isEmpty { return t("Enter a profile name.", "Introduce un nombre de perfil.") }
        if normalizedName.count > 40 || draft.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return t("Use 1–40 characters, without line breaks or control characters.", "Usa entre 1 y 40 caracteres, sin saltos de línea ni caracteres de control.")
        }
        if model.rows.contains(where: { $0.id != row?.id && $0.providerID == draft.providerID && $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame }) {
            return t("Another profile for this provider already has that name.", "Otro perfil de este proveedor ya tiene ese nombre.")
        }
        if let shortcut = draft.shortcut, model.rows.contains(where: { $0.id != row?.id && $0.shortcut == shortcut }) {
            return t("This shortcut is assigned to another profile.", "Este atajo está asignado a otro perfil.")
        }
        return nil
    }
    private var permitted: Bool {
        row?.canEdit ?? (model.providers.first { $0.id == draft.providerID }?.canCreate == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row {
                Label(model.providerName(row.providerID) + " · " + (row.isCurrent ? "Current" : t("Managed profile", "Perfil administrado")),
                      systemImage: row.isCurrent ? "person.crop.circle" : "person.crop.circle.badge.plus")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("ChatGPT/Codex").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Profile name", "Nombre del perfil")).font(.callout.bold())
                TextField(t("For example, Work", "Por ejemplo, Trabajo"), text: $draft.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(t("Profile name", "Nombre del perfil"))
                Text("\(normalizedName.count)/40").font(.caption2).foregroundStyle(.secondary)
            }
            if row == nil {
                Text(t("A free ⌥⌘ number shortcut is assigned automatically when available. You can change it later.", "Se asigna automáticamente un atajo numérico ⌥⌘ libre cuando haya uno disponible. Puedes cambiarlo después."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(t("Favorite", "Favorito"), isOn: $draft.favorite)
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Global shortcut", "Atajo global")).font(.callout.bold())
                    PairbarShortcutRecorder(shortcut: $draft.shortcut, language: model.language).frame(height: 28)
                    Text(t("Press a key with Command, Option or Control. Delete clears the shortcut.", "Pulsa una tecla con Comando, Opción o Control. Suprimir borra el atajo."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("Include in chosen profiles at login", "Incluir entre los perfiles elegidos al iniciar sesión"), isOn: $draft.openAtLogin)
            }
            if row?.isCurrent == true {
                Text(t("Current keeps the provider's normal storage. Its label and shortcut are preferences only.", "Current conserva el almacenamiento normal del proveedor. Su etiqueta y atajo son solo preferencias."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = validation, !draft.name.isEmpty {
                Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(t("Cancel", "Cancelar")) { model.showAccounts() }
                Spacer()
                Button(row == nil ? t("Create profile", "Crear perfil") : t("Save changes", "Guardar cambios")) {
                    var submitted = draft
                    submitted.name = normalizedName
                    if let row { model.send(.update(row.id, submitted)) }
                    else { model.send(.create(submitted)) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.previewOnly || model.busy || !permitted || validation != nil)
            }
        }
    }
}

/// Captures keys only while this native button is the first responder. It never
/// installs an event monitor or reads input from another application.
private struct PairbarShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: PairbarShortcut?
    var language: PairbarLanguage
    func makeNSView(context: Context) -> PairbarShortcutButton {
        let button = PairbarShortcutButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(PairbarShortcutButton.beginRecording)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(button)
        return button
    }
    func updateNSView(_ button: PairbarShortcutButton, context: Context) { configure(button) }
    private func configure(_ button: PairbarShortcutButton) {
        button.value = shortcut
        button.language = language
        button.onChange = { shortcut = $0 }
        button.refreshTitle()
    }
}

private final class PairbarShortcutButton: NSButton {
    var value: PairbarShortcut?
    var language = PairbarLanguage.system
    var onChange: ((PairbarShortcut?) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
        refreshTitle()
    }
    func refreshTitle() {
        title = recording ? language.text("Press shortcut…", "Pulsa el atajo…") : (value?.display ?? language.text("Record shortcut…", "Grabar atajo…"))
        setAccessibilityLabel(language.text("Global shortcut", "Atajo global"))
        setAccessibilityValue(title)
    }
    override func resignFirstResponder() -> Bool {
        recording = false
        refreshTitle()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { recording = false; refreshTitle(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            recording = false
            value = nil
            onChange?(nil)
            refreshTitle()
            return
        }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard HotKeys.isValid(keyCode: UInt32(event.keyCode), modifiers: modifiers) else {
            NSSound.beep()
            return
        }
        let next = PairbarShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        recording = false
        value = next
        onChange?(next)
        refreshTitle()
    }
}
