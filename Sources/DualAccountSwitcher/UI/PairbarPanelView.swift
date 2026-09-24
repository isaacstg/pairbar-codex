import AppKit
import SwiftUI

struct PairbarPanelView: View {
    @ObservedObject var model: PairbarPanelModel
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var searchExpanded = false
    @State private var confirmation: PairbarConfirmation?

    private func t(_ english: String, _ spanish: String) -> String { model.text(english, spanish) }
    private var title: String {
        switch model.page {
        case .accounts: return "Pairbar"
        case .welcome: return t("Welcome to Pairbar", "Te damos la bienvenida a Pairbar")
        case .settings: return t("Settings", "Ajustes")
        case .help: return t("Help", "Ayuda")
        case .create: return t("Add profile", "Añadir perfil")
        case .edit: return t("Edit profile", "Editar perfil")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.page == .accounts { searchAndFilters }
            Divider()
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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: PairbarPanelModel.width, height: PairbarPanelModel.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(keyboardCommands)
        .confirmationDialog(confirmation?.title(language: model.language) ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            Button(action.button(language: model.language)) {
                confirmation = nil
                model.send(action.action)
            }
            Button(t("Cancel", "Cancelar"), role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action.message(language: model.language))
        }
        .onChange(of: model.rows) { _ in model.pruneSelection() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.page != .accounts && model.page != .welcome {
                Button { model.showAccounts() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("Back to profiles", "Volver a perfiles"))
                    .help(t("Back to profiles · Shift-Command-B", "Volver a perfiles · Mayús-Comando-B"))
            }
            Text(title).font(.headline).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(t("Close popover", "Cerrar panel"))
                .help(t("Close · Escape", "Cerrar · Escape"))
        }.padding(16)
    }

    private var keyboardCommands: some View {
        HStack {
            Button("") {
                model.page = .accounts
                searchExpanded = true
                searchFocused = true
            }.keyboardShortcut("f", modifiers: .command)
            Button("") { model.showAccounts() }.keyboardShortcut("b", modifiers: [.command, .shift])
        }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 8) {
            HStack {
                Button { searchExpanded.toggle(); if searchExpanded { searchFocused = true } else { model.search = "" } } label: {
                    Label(t("Search", "Buscar"), systemImage: "magnifyingglass")
                }.buttonStyle(.borderless)
                Spacer()
                Menu {
                    Picker(t("Provider", "Proveedor"), selection: $model.providerFilter) {
                        Text(t("All", "Todos")).tag("all")
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                    }
                } label: { Label(t("Filter", "Filtrar"), systemImage: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton)
                Button(model.selecting ? t("Done", "Listo") : t("Select", "Elegir")) {
                    model.selecting.toggle()
                    if !model.selecting { model.selectedIDs = [] }
                }.buttonStyle(.borderless)
            }
            if searchExpanded || !model.search.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(t("Search profile names", "Buscar nombres de perfiles"), text: $model.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel(t("Search profiles", "Buscar perfiles"))
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(t("Clear search", "Borrar búsqueda"))
                }
            }.padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 16).padding(.bottom, 12)
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
        }
    }

    private var accounts: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
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
                Button(t("Recover " + provider.name + "…", "Recuperar " + provider.name + "…")) {
                    confirmation = .recover(provider)
                }.disabled(model.previewOnly || provider.busy)
            }
        }
    }

    private func profileRow(_ row: PairbarProfileRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(row.name).font(.headline).lineLimit(2).help(row.name)
                    if row.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel(t("Favorite", "Favorito")) }
                }
                Text(model.providerName(row.providerID) + " · " + (row.isCurrent ? "Current" : t("Profile", "Perfil")))
                    .font(.caption2).foregroundStyle(.secondary)
                if row.needsAttention || row.running || row.isBusy {
                    Label(row.status, systemImage: row.needsAttention ? "exclamationmark.circle" : (row.running ? "checkmark.circle.fill" : "circle"))
                        .font(.caption).foregroundStyle(row.needsAttention ? Color.orange : (row.running ? Color.green : Color.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Button { model.send(.open(row.id)) } label: {
                    HStack(spacing: 4) {
                        if row.isBusy { ProgressView().controlSize(.mini) }
                        Text(row.running ? t("Switch", "Cambiar") : t("Open", "Abrir"))
                    }.frame(minWidth: 62)
                }
                .disabled(model.previewOnly || !row.canOpen || row.isBusy)
                .accessibilityLabel((row.running ? t("Switch to", "Cambiar a") : t("Open", "Abrir")) + " " + row.name)
                .help(row.unavailableReason ?? row.shortcut?.display ?? "")
                HStack(spacing: 5) {
                    Text(row.shortcut?.display ?? "").font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                    rowMenu(row)
                }.frame(height: 16)
            }.frame(width: 92, alignment: .trailing)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func rowMenu(_ row: PairbarProfileRow) -> some View {
        Menu {
            Button(t("Edit profile…", "Editar perfil…")) { model.page = .edit(row.id) }.disabled(!row.canEdit)
            Button(row.favorite ? t("Remove favorite", "Quitar de favoritos") : t("Add favorite", "Añadir a favoritos")) {
                model.send(.favorite(row.id, !row.favorite))
            }.disabled(model.previewOnly || !row.canEdit)
            Button(t("Move up", "Subir")) { model.send(.move(row.id, -1)) }.disabled(model.previewOnly || !row.canEdit)
            Button(t("Move down", "Bajar")) { model.send(.move(row.id, 1)) }.disabled(model.previewOnly || !row.canEdit)
            if !row.isCurrent {
                Divider()
                Button(t("Restart…", "Reiniciar…")) { confirmation = .restart(row) }.disabled(model.previewOnly || !row.canRestart)
                Button(t("Close…", "Cerrar…")) { confirmation = .close(row) }.disabled(model.previewOnly || !row.canClose)
                Divider()
                Button(t("Archive & reset…", "Archivar y restablecer…")) { confirmation = .reset(row) }.disabled(model.previewOnly || !row.canReset)
                Button(t("Archive profile…", "Archivar perfil…")) { confirmation = .archive(row) }.disabled(model.previewOnly || !row.canArchive)
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
        .accessibilityLabel(t("Actions for", "Acciones de") + " " + row.name)
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
                t("Use favorites, search and shortcuts. Saving a profile does not open it or enable startup at login.", "Usa favoritos, búsqueda y atajos. Guardar un perfil no lo abre ni activa su inicio de sesión."))
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
        VStack(alignment: .leading, spacing: 18) {
            Picker(t("Language", "Idioma"), selection: Binding(get: { model.language }, set: { model.send(.setLanguage($0)) })) {
                Text(t("System", "Sistema")).tag(PairbarLanguage.system)
                Text("English").tag(PairbarLanguage.english)
                Text("Español").tag(PairbarLanguage.spanish)
            }.disabled(model.previewOnly)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(t("At login", "Al iniciar sesión")).font(.headline)
                Toggle(t("Start Pairbar at login", "Iniciar Pairbar al iniciar sesión"), isOn: Binding(
                    get: { model.startAtLogin }, set: { model.send(.setStartAtLogin($0)) }
                )).disabled(model.previewOnly || model.busy)
                if model.loginStatus == t("Approve in System Settings", "Requiere aprobación en Ajustes del Sistema") ||
                    model.loginStatus == t("Install Pairbar in Applications first", "Instala Pairbar en Aplicaciones primero") {
                    Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("Open chosen profiles at login", "Abrir perfiles elegidos al iniciar sesión"), isOn: Binding(
                    get: { model.openProfilesAtLogin }, set: { model.send(.setOpenProfilesAtLogin($0)) }
                )).disabled(model.previewOnly || model.busy)
                if model.openProfilesAtLogin {
                    if !model.startAtLogin {
                        Label(t("Enable Start Pairbar at login to use this selection.", "Activa el inicio de Pairbar para usar esta selección."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.orderedRows) { row in
                            Toggle(row.name + " · " + model.providerName(row.providerID), isOn: Binding(
                                get: { row.openAtLogin }, set: { model.send(.setProfileAtLogin(row.id, $0)) }
                            )).disabled(model.previewOnly || !row.canEdit)
                        }
                    }
                }
            }
            DisclosureGroup(t("Advanced", "Avanzado")) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.providers) { provider in providerSettings(provider) }
                    Button(t("Export configuration…", "Exportar configuración…")) { model.send(.exportConfiguration) }
                        .disabled(model.previewOnly || model.busy)
                }.padding(.top, 10)
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
            HStack {
                Button(t("Choose app…", "Elegir app…")) { model.send(.choose(provider.id)) }.disabled(!provider.canChoose)
                Button(t("Check again", "Comprobar")) { model.send(.check(provider.id)) }.disabled(!provider.canCheck)
            }.disabled(model.previewOnly || provider.busy)
            if provider.canRecover {
                Button(t("Try safe recovery…", "Intentar recuperación segura…")) { confirmation = .recover(provider) }
                    .disabled(model.previewOnly || provider.busy)
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(t("Quick start", "Guía de inicio")) { model.page = .welcome }
            Text(t("Find a profile with ⌘F. Use ⇧⌘B to return here to profiles, or Escape to close the panel. Configure a profile's global shortcut in its Edit menu.", "Busca un perfil con ⌘F. Usa ⇧⌘B para volver a perfiles, o Escape para cerrar el panel. Configura el atajo global de un perfil en su menú Editar."))
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
                Text(t("Archive & reset keeps the old data in an archive and starts with fresh storage next time. Archive profile removes it from the active list and startup selection. Both require every instance of that provider to be closed and no uncertain operation. Pairbar never immediately deletes profile data.", "Archivar y restablecer conserva los datos anteriores en un archivo e inicia con almacenamiento nuevo la próxima vez. Archivar perfil lo retira de la lista activa y del inicio automático. Ambas acciones requieren cerrar todas las instancias del proveedor y resolver cualquier operación incierta. Pairbar nunca borra inmediatamente los datos."))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            Divider()
            Text("Pairbar " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"))
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
        } else {
            HStack {
                Button { model.page = .settings } label: { Label(t("Settings", "Ajustes"), systemImage: "gearshape") }
                    .buttonStyle(.plain).disabled(model.page == .settings)
                Spacer()
                Button { model.page = .create } label: { Label(t("Add profile", "Añadir perfil"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(!model.canCreate || model.page == .create)
                Spacer()
                Button { model.page = .help } label: { Label(t("Help", "Ayuda"), systemImage: "questionmark.circle") }
                    .buttonStyle(.plain).disabled(model.page == .help)
            }.font(.callout).padding(16)
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

private enum PairbarConfirmation: Identifiable {
    case close(PairbarProfileRow), restart(PairbarProfileRow), archive(PairbarProfileRow), reset(PairbarProfileRow), recover(PairbarProviderRow)
    var id: String {
        switch self {
        case .close(let row): return "close:" + row.id
        case .restart(let row): return "restart:" + row.id
        case .archive(let row): return "archive:" + row.id
        case .reset(let row): return "reset:" + row.id
        case .recover(let provider): return "recover:" + provider.id
        }
    }
    var action: PairbarPanelAction {
        switch self {
        case .close(let row): return .close(row.id)
        case .restart(let row): return .restart(row.id)
        case .archive(let row): return .archive(row.id)
        case .reset(let row): return .reset(row.id)
        case .recover(let provider): return .recover(provider.id)
        }
    }
    func title(language: PairbarLanguage) -> String {
        let name: String
        switch self {
        case .close(let row), .restart(let row), .archive(let row), .reset(let row): name = row.name
        case .recover(let provider): name = provider.name
        }
        return button(language: language) + " · " + name + "?"
    }
    func button(language: PairbarLanguage) -> String {
        switch self {
        case .close: return language.text("Close profile", "Cerrar perfil")
        case .restart: return language.text("Restart profile", "Reiniciar perfil")
        case .archive: return language.text("Archive profile", "Archivar perfil")
        case .reset: return language.text("Archive & reset", "Archivar y restablecer")
        case .recover: return language.text("Try safe recovery", "Intentar recuperación segura")
        }
    }
    func message(language: PairbarLanguage) -> String {
        switch self {
        case .close, .restart:
            return language.text("Save your work first. Pairbar rechecks ownership before requesting a normal close. Current is never closed by Pairbar.", "Guarda tu trabajo primero. Pairbar vuelve a comprobar la propiedad antes de solicitar un cierre normal. Pairbar nunca cierra Current.")
        case .archive:
            return language.text("This profile will leave the active list and startup selection. Its data will be archived, not deleted. Every instance of this provider must be closed first.", "Este perfil se retirará de la lista activa y del inicio automático. Sus datos se archivarán, sin borrarlos. Primero deben cerrarse todas las instancias de este proveedor.")
        case .reset:
            return language.text("Existing data will be archived. The profile keeps its name and uses fresh storage next time; you will need to sign in again. Every instance of this provider must be closed first.", "Se archivarán los datos existentes. El perfil conservará su nombre y usará almacenamiento nuevo la próxima vez; tendrás que iniciar sesión de nuevo. Primero deben cerrarse todas las instancias de este proveedor.")
        case .recover:
            return language.text("Pairbar will verify recorded processes conservatively. If it cannot establish ownership, it preserves the uncertain state and asks for manual recovery. No process will be adopted by approximation.", "Pairbar verificará los procesos registrados de forma conservadora. Si no puede demostrar la propiedad, conservará el estado incierto y solicitará recuperación manual. No asumirá la propiedad de procesos por aproximación.")
        }
    }
}
