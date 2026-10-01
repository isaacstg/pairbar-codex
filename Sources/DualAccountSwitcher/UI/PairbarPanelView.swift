import AppKit
import SwiftUI

struct PairbarPanelView: View {
    @ObservedObject var model: PairbarPanelModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: PairbarConfirmation?
    @State private var hoveredRowID: String?

    private func t(_ english: String, _ spanish: String) -> String { model.text(english, spanish) }
    private var isRestorePage: Bool { if case .restore = model.page { return true }; return false }
    private var title: String {
        switch model.page {
        case .accounts: return "Pairbar"
        case .welcome: return t("Welcome to Pairbar", "Te damos la bienvenida a Pairbar")
        case .settings: return t("Settings", "Ajustes")
        case .help: return t("Help", "Ayuda")
        case .create: return t("Add profile", "Añadir perfil")
        case .edit: return t("Edit profile", "Editar perfil")
        case .restore: return t("Restore Profile", "Restaurar perfil")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if model.page == .accounts && (model.searchExpanded || model.showsProviderFilter || model.showsSelectionControl) { searchAndFilters }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = model.errorMessage { errorBanner(message) }
                    if let message = model.progressMessage {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message).font(.caption)
                        }.accessibilityElement(children: .combine)
                    }
                    pageContent
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.page == .welcome || (model.page == .accounts && model.selecting) { footer }
        }
        .frame(width: model.desiredContentSize.width, height: model.desiredContentSize.height)
        .overlayPreferenceValue(PairbarActionAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if model.page == .accounts,
                   let id = model.expandedActionsID,
                   let row = model.visibleRows.first(where: { $0.id == id }),
                   let anchor = anchors[id] {
                    PairbarActionOverlayLayout(anchor: geometry[anchor]) {
                        rowActions(row)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(keyboardCommands)
        .confirmationDialog(confirmation?.title(language: model.language) ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { setConfirmation(nil) } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            Button(action.button(language: model.language)) {
                setConfirmation(nil)
                model.send(action.action)
            }
            Button(t("Cancel", "Cancelar"), role: .cancel) { setConfirmation(nil) }
        } message: { action in
            Text(action.message(language: model.language))
        }
        .onChange(of: model.rows) { _ in model.pruneSelection() }
        .onChange(of: model.desiredContentSize) { size in model.onDesiredContentSizeChange?(size) }
        .onChange(of: model.page) { page in
            if page != .accounts { model.searchExpanded = false; model.search = ""; searchFocused = false }
        }
    }

    private func setConfirmation(_ value: PairbarConfirmation?) {
        model.confirmationPresented = value != nil
        confirmation = value
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.page != .accounts && model.page != .welcome {
                Button { if isRestorePage { model.page = .settings } else { model.showAccounts() } } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isRestorePage ? t("Back to Settings", "Volver a Ajustes") : t("Back to profiles", "Volver a perfiles"))
                    .help(isRestorePage ? t("Back to Settings", "Volver a Ajustes") : t("Back to profiles · Shift-Command-B", "Volver a perfiles · Mayús-Comando-B"))
            }
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 4)
            if model.page == .accounts {
                headerIcon("magnifyingglass", t("Search profiles", "Buscar perfiles")) {
                    if model.searchExpanded { model.searchExpanded = false; model.search = ""; searchFocused = false }
                    else { revealSearch() }
                }
                headerIcon("plus", t("Add profile", "Añadir perfil")) { model.page = .create }
                    .disabled(!model.canCreate)
                headerIcon("gearshape", t("Settings", "Ajustes")) { model.page = .settings }
            } else if model.page == .settings {
                headerIcon("questionmark.circle", t("Help", "Ayuda")) { model.page = .help }
            }
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func headerIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36) }
            .buttonStyle(.plain).contentShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(label).help(label)
    }

    private var keyboardCommands: some View {
        HStack {
            Button("") {
                model.page = .accounts
                revealSearch()
            }.keyboardShortcut("f", modifiers: .command)
            Button("") { model.showAccounts() }.keyboardShortcut("b", modifiers: [.command, .shift])
        }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
    }

    private func revealSearch() {
        model.searchExpanded = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private var searchAndFilters: some View {
        VStack(spacing: 9) {
            if model.showsProviderFilter || model.showsSelectionControl {
                HStack {
                    if model.showsProviderFilter {
                        Picker(t("Provider", "Proveedor"), selection: $model.providerFilter) {
                            Text(t("All", "Todos")).tag("all")
                            ForEach(model.visibleProviderIDs, id: \.self) { id in Text(model.providerName(id)).tag(id) }
                        }.pickerStyle(.segmented).accessibilityLabel(t("Filter profiles by provider", "Filtrar perfiles por proveedor"))
                    }
                    Spacer(minLength: 0)
                    if model.showsSelectionControl {
                        Button(model.selecting ? t("Done", "Listo") : t("Select", "Elegir")) {
                            model.selecting.toggle()
                            if !model.selecting { model.selectedIDs = [] }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if model.searchExpanded || !model.search.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(t("Search profile names", "Buscar nombres de perfiles"), text: $model.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onAppear {
                        DispatchQueue.main.async {
                            if model.page == .accounts && (model.searchExpanded || !model.search.isEmpty) { searchFocused = true }
                        }
                    }
                    .accessibilityLabel(t("Search profiles", "Buscar perfiles"))
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(t("Clear search", "Borrar búsqueda"))
                }
            }.padding(.horizontal, 10).frame(height: 34)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.07)))
            }
        }.padding(.horizontal, 16).padding(.bottom, 8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.searchExpanded)
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .accounts: accounts
        case .welcome: welcome
        case .settings: settings
        case .help: help
        case .create:
            PairbarProfileEditor(model: model, row: nil)
                .id("create")
        case .edit(let id):
            if let row = model.rows.first(where: { $0.id == id }) {
                PairbarProfileEditor(model: model, row: row).id(id)
            } else {
                Text(t("This profile is no longer available.", "Este perfil ya no está disponible."))
                Button(t("Back to profiles", "Volver a perfiles")) { model.showAccounts() }
            }
        case .restore(let id):
            VStack(alignment: .leading, spacing: 14) {
                Text(t("This name is already in use. Choose another name to restore the profile.",
                       "Este nombre ya está en uso. Elige otro para restaurar el perfil."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(t("Profile name", "Nombre del perfil"), text: $model.restoreName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(t("Cancel", "Cancelar")) { model.page = .settings }
                    Spacer()
                    Button(t("Restore", "Restaurar")) { model.send(.restore(id, model.restoreName)) }
                        .disabled(!model.restoreNameValid(for: id) || model.busy || model.previewOnly)
                }
            }
        }
    }

    private var accounts: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
                if model.memoryPressure != .normal {
                    Label(model.memoryPressure == .critical
                        ? t("Memory pressure is critical. Automatic openings are paused.", "La presión de memoria es crítica. Las aperturas automáticas están en pausa.")
                        : t("Memory pressure is elevated. Open only the profiles you need.", "La presión de memoria es elevada. Abre solo los perfiles que necesitas."), systemImage: "memorychip")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.visibleRows.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("No matching profiles", "No hay perfiles coincidentes")).font(.headline)
                        Text(t("Try another name or provider filter.", "Prueba otro nombre o filtro de proveedor."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                ForEach(model.visibleRows) { row in profileRow(row) }
                ForEach(model.providers.filter(\.canRecover)) { provider in
                    HStack {
                        Text(t("Pairbar needs to verify this account before it can be opened.", "Pairbar necesita verificar esta cuenta antes de abrirla."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Repair…", "Reparar…")) { setConfirmation(.recover(provider)) }
                            .disabled(model.previewOnly || provider.busy)
                    }
                }
        }
    }

    private func profileRow(_ row: PairbarProfileRow) -> some View {
        HStack(spacing: 2) {
            if model.selecting {
                Toggle(t("Select", "Elegir") + " " + row.name, isOn: Binding(
                    get: { model.selectedIDs.contains(row.id) },
                    set: { selected in
                        if selected { model.selectedIDs.insert(row.id) }
                        else { model.selectedIDs.remove(row.id) }
                    }
                )).toggleStyle(.checkbox).labelsHidden()
                    .disabled(!row.canOpen || row.isBusy)
            }
            Button { model.openRow(row) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(row.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if row.isCurrent { Text(t("Current", "Actual")).font(.system(size: 10)).foregroundStyle(.tertiary) }
                        if row.favorite { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary).accessibilityHidden(true) }
                        Spacer(minLength: 4)
                        if let shortcut = row.shortcut {
                            Text(shortcut.display).font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle().fill(row.needsAttention ? Color.orange : row.running ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(row.needsAttention || row.isBusy ? row.status : row.running ? t("Running", "En ejecución") : t("Stopped", "Detenido"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .padding(.leading, 10)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(hoveredRowID == row.id ? Color.accentColor.opacity(0.07) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(PairbarRowButtonStyle())
            .disabled(model.previewOnly || !row.canOpen || row.isBusy)
            .accessibilityLabel((row.running ? t("Switch to", "Cambiar a") : t("Open", "Abrir")) + " " + row.name)
            .help(row.unavailableReason ?? (row.running ? t("Switch", "Cambiar") : t("Open", "Abrir")))
            .onHover { hoveredRowID = $0 ? row.id : nil }
            Button { model.toggleActions(for: row.id) } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .frame(width: PairbarActionHitTarget.side, height: PairbarActionHitTarget.side)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PairbarEllipsisButtonStyle(isExpanded: model.expandedActionsID == row.id))
            .contentShape(Rectangle())
            .accessibilityLabel(t("Actions for", "Acciones de") + " " + row.name)
            .accessibilityValue(model.expandedActionsID == row.id ? t("Expanded", "Expandido") : t("Collapsed", "Contraído"))
            .anchorPreference(key: PairbarActionAnchorKey.self, value: .bounds) { [row.id: $0] }
        }
        .frame(height: 64)
        .accessibilityElement(children: .contain)
    }

    private func rowActions(_ row: PairbarProfileRow) -> some View {
        VStack(spacing: 1) {
            panelAction(t("Edit", "Editar"), "pencil", enabled: row.canEdit) {
                model.closeActions(); model.page = .edit(row.id)
            }
            panelAction(row.favorite ? t("Unpin", "Desfijar") : t("Pin", "Fijar"),
                        row.favorite ? "pin.slash" : "pin", enabled: !model.previewOnly && row.canEdit) {
                model.pin(row)
            }
            if model.canOfferClose(row) {
                panelAction(t("Close", "Cerrar"), "xmark.circle", enabled: !model.previewOnly) {
                    model.closeActions(); setConfirmation(.close(row))
                }
            }
            if model.canOfferRestart(row) {
                panelAction(t("Restart", "Reiniciar"), "arrow.clockwise", enabled: !model.previewOnly) {
                    model.closeActions(); setConfirmation(.restart(row))
                }
            }
            if model.canOfferDelete(row) {
                Divider().padding(.vertical, 3)
                panelAction(t("Remove from Pairbar…", "Quitar de Pairbar…"), "minus.circle",
                            enabled: !model.previewOnly, destructive: true) {
                    model.closeActions(); setConfirmation(.delete(row))
                }
            }
        }
        .padding(7)
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.09)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func panelAction(_ title: String, _ symbol: String, enabled: Bool,
                             destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PairbarActionButtonStyle())
        .foregroundStyle(destructive ? Color.red : Color.primary)
        .disabled(!enabled)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.2.fill").font(.system(size: 32)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(t("Your accounts, close at hand.", "Tus cuentas, siempre a mano.")).font(.title3.bold())
            Text(t("Pairbar lives in the Mac menu bar. Open this panel to switch accounts, find a profile or change settings.", "Pairbar vive en la barra de menú del Mac. Abre este panel para cambiar de cuenta, encontrar un perfil o ajustar tus preferencias."))
                .font(.callout).foregroundStyle(.secondary)
            welcomeStep("1", t("Keep your Current account", "Conserva tu cuenta Current"),
                t("Current opens the provider's normal app. Pairbar never closes, restarts or resets it.", "Current abre la app normal del proveedor. Pairbar nunca la cierra, reinicia ni restablece."))
            welcomeStep("2", t("Add profiles when you need them", "Añade perfiles cuando los necesites"),
                t("Name each profile and sign in inside its own app window. Your saved Current and Second setup is preserved.", "Pon nombre a cada perfil e inicia sesión en su propia ventana. Se conserva tu configuración de Current y Second."))
            welcomeStep("3", t("Choose what opens", "Elige qué se abre"),
                t("Use pins, search and shortcuts. Saving a profile does not open it or enable startup at login.", "Usa perfiles fijados, búsqueda y atajos. Guardar un perfil no lo abre ni activa su inicio de sesión."))
        }
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold()).frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Text(t("General", "General")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker(t("Language", "Idioma"), selection: Binding(get: { model.language }, set: { model.send(.setLanguage($0)) })) {
                    Text(t("System", "Sistema")).tag(PairbarLanguage.system)
                    Text("English").tag(PairbarLanguage.english)
                    Text("Español").tag(PairbarLanguage.spanish)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(t("At login", "Al iniciar sesión")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Toggle(t("Start Pairbar at login", "Iniciar Pairbar al iniciar sesión"), isOn: Binding(
                    get: { model.startAtLogin }, set: { model.send(.setStartAtLogin($0)) }
                )).disabled(model.busy)
                if model.loginStatus == t("Approve in System Settings", "Requiere aprobación en Ajustes del Sistema") ||
                    model.loginStatus == t("Install Pairbar in Applications first", "Instala Pairbar en Aplicaciones primero") {
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("Open chosen profiles at login", "Abrir perfiles elegidos al iniciar sesión"), isOn: Binding(
                    get: { model.openProfilesAtLogin }, set: { model.send(.setOpenProfilesAtLogin($0)) }
                )).disabled(model.busy)
                if model.openProfilesAtLogin {
                    if !model.startAtLogin {
                        Label(t("Enable Start Pairbar at login to use this selection.", "Activa el inicio de Pairbar para usar esta selección."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.orderedRows) { row in
                            Toggle(row.name + " · " + model.providerName(row.providerID), isOn: Binding(
                                get: { row.openAtLogin }, set: { model.send(.setProfileAtLogin(row.id, $0)) }
                            )).disabled(!row.canEdit)
                        }
                    }
                }
            }.padding(.top, 2)
            if !model.removedProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Removed Profiles", "Perfiles quitados"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.removedProfiles) { row in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.callout).lineLimit(1)
                                Text(t("Local data kept", "Datos locales conservados"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button(t("Restore", "Restaurar")) { model.send(.restore(row.id, nil)) }
                                .disabled(model.busy || model.previewOnly || !row.canEdit)
                        }.padding(.vertical, 3)
                    }
                }
            }
            DisclosureGroup(isExpanded: $model.advancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.providers) { provider in providerSettings(provider) }
                    Button(t("Export configuration…", "Exportar configuración…")) { model.send(.exportConfiguration) }
                        .disabled(model.previewOnly || model.busy)
                    Button(t("Help & About", "Ayuda e información")) { model.page = .help }
                }.padding(.top, 6)
            } label: {
                Text(t("Advanced", "Avanzado")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func providerSettings(_ provider: PairbarProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.name).font(.headline)
                if provider.busy { ProgressView().controlSize(.small) }
                Spacer()
                if !provider.version.isEmpty { Text(provider.version).font(.caption).foregroundStyle(.secondary) }
            }
            Text(provider.status).font(.callout)
            if !provider.detail.isEmpty { Text(provider.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if provider.id == "claude", let current = model.rows.first(where: { $0.providerID == "claude" && $0.isCurrent }) {
                HStack {
                    Text(current.name + " · " + t("Current", "Actual")).font(.callout)
                    Spacer()
                    Button(t("Open", "Abrir")) { model.openRow(current) }
                        .disabled(model.previewOnly || !current.canOpen || current.isBusy)
                    Button(t("Edit profile…", "Editar perfil…")) { model.page = .edit(current.id) }
                        .disabled(!current.canEdit)
                }
            }
            HStack {
                Button(t("Choose app…", "Elegir app…")) { model.send(.choose(provider.id)) }.disabled(!provider.canChoose)
                Button(t("Check again", "Comprobar")) { model.send(.check(provider.id)) }.disabled(!provider.canCheck)
            }.disabled(model.previewOnly || provider.busy)
            if provider.canRecover {
                Button(t("Try safe recovery…", "Intentar recuperación segura…")) { setConfirmation(.recover(provider)) }
                    .disabled(model.previewOnly || provider.busy)
            }
        }
    }

    private var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "Pairbar \(version) (\(build))"
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(t("Quick start", "Guía de inicio")) { model.page = .welcome }
            Text(t("Find a profile with ⌘F. Use ⇧⌘B to return to profiles, or Escape to close the panel. Configure a global shortcut in a profile's Edit actions.", "Busca un perfil con ⌘F. Usa ⇧⌘B para volver a perfiles, o Escape para cerrar el panel. Configura un atajo global en las acciones Editar del perfil."))
                .font(.callout).foregroundStyle(.secondary)
            Text(t("Current is the normal app for each provider. It has no close, restart, archive or reset action. Managed profiles expose lifecycle actions only when ownership is verified.", "Current es la app normal de cada proveedor. No tiene acciones para cerrar, reiniciar, archivar ni restablecer. Los perfiles administrados solo ofrecen controles cuando se verifica su propiedad."))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("If ownership is uncertain, Pairbar pauses the affected provider. Safe recovery verifies existing receipts; it never takes over a process by guesswork.", "Si la propiedad es incierta, Pairbar pausa el proveedor afectado. La recuperación segura verifica recibos existentes; nunca asume la propiedad de un proceso por aproximación."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup(t("Redacted diagnostics", "Diagnósticos redactados")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("Only Pairbar state is included. Personal labels, account identities and sign-in data are excluded.", "Solo se incluye el estado de Pairbar. Se excluyen etiquetas personales, identidades de cuentas y datos de inicio de sesión."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(t("Copy diagnostics", "Copiar diagnósticos")) { model.send(.copyDiagnostics) }
                        Button(t("Clear log", "Vaciar registro")) { model.send(.clearDiagnostics) }
                    }.disabled(model.previewOnly)
                    Text(model.diagnosticText).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 8)
            }
            DisclosureGroup(t("Reset and archive", "Restablecer y archivar")) {
                Text(t("Remove from Pairbar keeps the profile's local data. If it is open, Pairbar closes only that verified profile first. Archive & reset keeps the old data in an archive and starts with fresh storage next time; it still requires every instance of that provider to be closed.", "Quitar de Pairbar conserva los datos locales del perfil. Si está abierto, Pairbar cierra primero solo ese perfil verificado. Archivar y restablecer conserva los datos anteriores e inicia con almacenamiento nuevo; sigue exigiendo cerrar todas las instancias del proveedor."))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            Divider()
            Text(displayVersion)
                .font(.caption).foregroundStyle(.secondary)
            Text(t("Local only. No telemetry, network requests or automatic updates. Official provider apps remain unchanged.", "Solo local. Sin telemetría, solicitudes de red ni actualizaciones automáticas. Las apps oficiales permanecen sin cambios."))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("Independent utility. Not affiliated with OpenAI or Anthropic.", "Utilidad independiente. Sin afiliación con OpenAI ni Anthropic."))
                .font(.caption).foregroundStyle(.secondary)
            Button(t("Quit Pairbar", "Salir de Pairbar")) { model.send(.quitPairbar) }.disabled(model.previewOnly)
                .help(t("Provider apps keep running.", "Las apps de los proveedores seguirán abiertas."))
        }
    }

    @ViewBuilder private var footer: some View {
        if model.page == .welcome {
            HStack {
                Text(t("Available again in Help.", "Disponible de nuevo en Ayuda."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("Go to profiles", "Ir a perfiles")) { model.completeWelcome() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        } else if model.page == .accounts && model.selecting {
            HStack {
                Text(t("Selected", "Elegidos") + ": \(model.selectedOpenableIDs.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("Open selected", "Abrir elegidos")) {
                    let ids = model.selectedOpenableIDs
                    model.send(.openSelected(ids))
                }.buttonStyle(.borderedProminent)
                    .disabled(model.previewOnly || model.selectedOpenableIDs.isEmpty || model.busy)
            }.padding(16)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(t("Needs attention", "Requiere atención"), systemImage: "exclamationmark.circle").font(.callout.bold())
                Spacer()
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(t("Dismiss message", "Ocultar mensaje"))
            }
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PairbarActionAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

enum PairbarActionHitTarget {
    static let side: CGFloat = 44
}

/// Places the measured panel beside its ellipsis, then keeps it inside the native popover.
struct PairbarActionPlacement {
    static func origin(anchor: CGRect, panel: CGSize, bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 8
        let preferredX = anchor.minX - panel.width
        let preferredY = anchor.midY - 40
        return CGPoint(
            x: min(max(preferredX, bounds.minX + inset), max(bounds.minX + inset, bounds.maxX - panel.width - inset)),
            y: min(max(preferredY, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - panel.height - inset))
        )
    }
}

private struct PairbarActionOverlayLayout: Layout {
    let anchor: CGRect
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let size = panel.sizeThatFits(.unspecified)
        panel.place(at: PairbarActionPlacement.origin(anchor: anchor, panel: size, bounds: bounds),
                    proposal: ProposedViewSize(size))
    }
}

private struct PairbarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct PairbarActionButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.18) : hovering ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

private struct PairbarEllipsisButtonStyle: ButtonStyle {
    let isExpanded: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: PairbarActionHitTarget.side, height: PairbarActionHitTarget.side)
            .contentShape(Rectangle())
            .background(
                configuration.isPressed ? Color.accentColor.opacity(0.18)
                : hovering ? Color.accentColor.opacity(0.09)
                : isExpanded ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .onHover { hovering = $0 }
    }
}

enum PairbarConfirmation: Identifiable {
    case close(PairbarProfileRow), restart(PairbarProfileRow), delete(PairbarProfileRow), archive(PairbarProfileRow), reset(PairbarProfileRow), recover(PairbarProviderRow)
    var id: String {
        switch self {
        case .close(let row): return "close:" + row.id
        case .restart(let row): return "restart:" + row.id
        case .delete(let row): return "delete:" + row.id
        case .archive(let row): return "archive:" + row.id
        case .reset(let row): return "reset:" + row.id
        case .recover(let provider): return "recover:" + provider.id
        }
    }
    var action: PairbarPanelAction {
        switch self {
        case .close(let row): return .close(row.id)
        case .restart(let row): return .restart(row.id)
        case .delete(let row): return .delete(row.id)
        case .archive(let row): return .archive(row.id)
        case .reset(let row): return .reset(row.id)
        case .recover(let provider): return .recover(provider.id)
        }
    }
    func title(language: PairbarLanguage) -> String {
        let name: String
        switch self {
        case .close(let row), .restart(let row), .delete(let row), .archive(let row), .reset(let row): name = row.name
        case .recover(let provider): name = provider.name
        }
        return button(language: language) + " · " + name + "?"
    }
    func button(language: PairbarLanguage) -> String {
        switch self {
        case .close: return language.text("Close profile", "Cerrar perfil")
        case .restart: return language.text("Restart profile", "Reiniciar perfil")
        case .delete: return language.text("Remove from Pairbar", "Quitar de Pairbar")
        case .archive: return language.text("Archive profile", "Archivar perfil")
        case .reset: return language.text("Archive & reset", "Archivar y restablecer")
        case .recover: return language.text("Try safe recovery", "Intentar recuperación segura")
        }
    }
    func message(language: PairbarLanguage) -> String {
        switch self {
        case .close, .restart:
            return language.text("Save your work first. Pairbar rechecks ownership before requesting a normal close. Current is never closed by Pairbar.", "Guarda tu trabajo primero. Pairbar vuelve a comprobar la propiedad antes de solicitar un cierre normal. Pairbar nunca cierra Current.")
        case .delete:
            return language.text("This removes the profile from Pairbar. Its local data is kept. You can restore it later from Settings.", "Esto quita el perfil de Pairbar. Sus datos locales se conservan. Puedes restaurarlo más adelante desde Ajustes.")
        case .archive:
            return language.text("This profile will leave the active list and startup selection. Its data will be archived, not deleted. Every instance of this provider must be closed first.", "Este perfil se retirará de la lista activa y del inicio automático. Sus datos se archivarán, sin borrarlos. Primero deben cerrarse todas las instancias de este proveedor.")
        case .reset:
            return language.text("Existing data will be archived. The profile keeps its name and uses fresh storage next time; you will need to sign in again. Every instance of this provider must be closed first.", "Se archivarán los datos existentes. El perfil conservará su nombre y usará almacenamiento nuevo la próxima vez; tendrás que iniciar sesión de nuevo. Primero deben cerrarse todas las instancias de este proveedor.")
        case .recover:
            return language.text("Pairbar will check whether ChatGPT is closed and whether this account can be opened safely. If the issue remains, close ChatGPT and check Advanced.", "Pairbar comprobará si ChatGPT está cerrado y si esta cuenta puede abrirse con seguridad. Si el problema continúa, cierra ChatGPT y revisa Avanzado.")
        }
    }
}
