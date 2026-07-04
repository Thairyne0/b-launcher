import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `FileDocument` leggero che avvolge i bytes JSON già serializzati di un `ProjectTemplate` —
/// usato solo per pilotare `.fileExporter`, nessuna logica propria (il contenuto è calcolato
/// prima, da `ProjectTemplateCodec`/`ServiceStore.exportTemplate`).
/// Estensione desiderata "`.blauncher.json`" ma UTType usa il generico `.json`: registrare uno
/// UTType custom solo per la naming non vale la complessità aggiuntiva per un file picker.
struct TemplateJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Selezione corrente nella sidebar: griglia completa, vista Focus, singolo servizio, o
/// griglia filtrata su un singolo progetto (righe progetto cliccabili, Phase F).
enum SidebarSelection: Hashable {
    case grid
    case focus
    case service(String)
    case project(String)
}

/// Serializzazione pura `SidebarSelection` <-> stringa per @AppStorage
/// ("grid" / "focus" / "service:<id>" / "project:<id>").
enum SidebarSelectionCoding {
    private static let servicePrefix = "service:"
    private static let projectPrefix = "project:"

    static func encode(_ selection: SidebarSelection) -> String {
        switch selection {
        case .grid: return "grid"
        case .focus: return "focus"
        case .service(let id): return servicePrefix + id
        case .project(let id): return projectPrefix + id
        }
    }

    /// Decodifica permissiva: qualunque stringa non riconosciuta ricade su `.grid`.
    static func decode(_ raw: String) -> SidebarSelection {
        if raw == "grid" { return .grid }
        if raw == "focus" { return .focus }
        if raw.hasPrefix(servicePrefix) {
            let id = String(raw.dropFirst(servicePrefix.count))
            guard !id.isEmpty else { return .grid }
            return .service(id)
        }
        if raw.hasPrefix(projectPrefix) {
            let id = String(raw.dropFirst(projectPrefix.count))
            guard !id.isEmpty else { return .grid }
            return .project(id)
        }
        return .grid
    }
}

/// Sidebar del progetto: griglia, Focus, e un rigo per servizio con stato live, con
/// wizard add/edit/delete di progetti e servizi (Phase D).
struct SidebarView: View {
    var model: AppModel
    @Binding var selection: SidebarSelection
    /// Chiamato con l'esito di una scansione cartella (bottone "Scansiona cartella…") + la
    /// root scelta. Lo stato della sheet `ScanResultsSheet` vive in `ContentView` (non qui) per
    /// poter essere condiviso col flusso di drag&drop, che vive anch'esso in `ContentView` — la
    /// sidebar si limita a produrre l'evento, non possiede la presentazione.
    var onScanRequested: (ProjectScanner.ScanResult, URL) -> Void = { _, _ in }
    @Environment(\.openWindow) private var openWindow

    @State private var addingServiceToProject: String?
    @State private var editingService: (projectID: String, originalName: String)?
    @State private var deletingService: (projectID: String, name: String)?
    @State private var deletingProject: String?
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var newProjectError: String?
    @State private var exportingProject: String?
    @State private var showImportSheet = false
    @State private var settingsProject: String?
    /// Progetto per cui è stato richiesto un cambio di cartella radice (dal menu contestuale
    /// della sidebar): pilota il `.fileImporter` di rebase, condiviso da tutti i progetti così
    /// da non dover tenere uno stato/picker per riga.
    @State private var rebasingProject: String?
    @State private var rebaseError: String?
    /// Progetti collassati (per id) — set vuoto di default: TUTTI i progetti partono espansi
    /// senza dover pre-popolare nulla da `projects` (evita di dover reagire a progetti nuovi).
    @State private var collapsedProjects: Set<String> = []
    // (Storicamente qui viveva `showPromptCopiedConfirmation`, che pilotava uno scambio
    // transiente di label sul bottone "Genera con Claude Code…". Da quando l'azione è entrata
    // nel Menu "Aggiungi progetto" (design-polish pass) quel bottone si smonta nell'istante in
    // cui l'item viene selezionato — il menu si chiude subito — quindi una label interna al
    // menu non sarebbe mai visibile. La conferma transiente è stata sostituita da un toast
    // (`ToastCenter`), coerente con le altre conferme "fire and forget" dell'app.)

    /// `List(selection:)` richiede un binding opzionale; un deselect (nil) ricade su `.grid`
    /// così la vista di dettaglio ha sempre una selezione valida.
    private var listSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selection = $0 ?? .grid }
        )
    }

    /// Binding di espansione per un dato progetto: derivato da `collapsedProjects` (assente
    /// = espanso). Invertito rispetto allo storage per far sì che il default (set vuoto)
    /// corrisponda a "tutti espansi".
    private func expansionBinding(forProjectID id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(id) },
            set: { isExpanded in
                if isExpanded { collapsedProjects.remove(id) } else { collapsedProjects.insert(id) }
            }
        )
    }

    var body: some View {
        List(selection: listSelection) {
            if let projects = model.store?.projects, !projects.isEmpty {
                Section {
                    Label("Griglia", systemImage: "square.grid.2x2")
                        .tag(SidebarSelection.grid)

                    Label("Focus", systemImage: "rectangle.on.rectangle")
                        .tag(SidebarSelection.focus)
                }

                Section {
                    ForEach(projects) { project in
                        projectDisclosureRow(project)
                            .contextMenu {
                                projectContextMenuContent(project)
                            }
                    }
                }
            } else {
                Section {
                    navigationRowsFallback
                }
            }

            Section {
                Menu {
                    Button("Nuovo progetto", systemImage: "folder.badge.plus") {
                        newProjectName = ""
                        newProjectError = nil
                        showNewProjectAlert = true
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button("Scansiona cartella…", systemImage: "doc.text.magnifyingglass") {
                        scanFolder()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Button("Importa progetto…", systemImage: "square.and.arrow.down") {
                        showImportSheet = true
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                    Divider()

                    Button("Genera con Claude Code…", systemImage: "sparkles") {
                        copyClaudeCodePrompt()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                } label: {
                    Label("Aggiungi progetto", systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .sheet(item: Binding(
            get: { addingServiceToProject.map(SheetProjectID.init) },
            set: { addingServiceToProject = $0?.id }
        )) { wrapped in
            ServiceFormSheet(model: model, projectID: wrapped.id, mode: .add) {
                addingServiceToProject = nil
            }
        }
        .sheet(item: Binding(
            get: { editingService.map { SheetEditTarget(projectID: $0.projectID, originalName: $0.originalName) } },
            set: { editingService = $0.map { ($0.projectID, $0.originalName) } }
        )) { target in
            ServiceFormSheet(model: model, projectID: target.projectID, mode: .edit(originalName: target.originalName)) {
                editingService = nil
            }
        }
        .sheet(item: Binding(
            get: { exportingProject.map(SheetProjectID.init) },
            set: { exportingProject = $0?.id }
        )) { wrapped in
            ExportTemplateSheet(model: model, projectID: wrapped.id) {
                exportingProject = nil
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportTemplateSheet(model: model) {
                showImportSheet = false
            }
        }
        .sheet(item: Binding(
            get: { settingsProject.map(SheetProjectID.init) },
            set: { settingsProject = $0?.id }
        )) { wrapped in
            ProjectSettingsSheet(model: model, projectID: wrapped.id) {
                settingsProject = nil
            }
        }
        .fileImporter(isPresented: Binding(
            get: { rebasingProject != nil },
            set: { if !$0 { rebasingProject = nil } }
        ), allowedContentTypes: [.folder]) { result in
            handleRebasePick(result)
        }
        .alert("Impossibile cambiare cartella", isPresented: Binding(
            get: { rebaseError != nil },
            set: { if !$0 { rebaseError = nil } }
        )) {
            Button("OK", role: .cancel) { rebaseError = nil }
        } message: {
            Text(rebaseError ?? "")
        }
        .confirmationDialog(
            "Eliminare questo backend?",
            isPresented: Binding(
                get: { deletingService != nil },
                set: { if !$0 { deletingService = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                if let target = deletingService {
                    confirmDeleteService(projectID: target.projectID, name: target.name)
                }
                deletingService = nil
            }
            Button("Annulla", role: .cancel) { deletingService = nil }
        } message: {
            Text("Il backend verrà rimosso dal progetto. Se in esecuzione, verrà prima fermato.")
        }
        .confirmationDialog(
            "Eliminare questo progetto?",
            isPresented: Binding(
                get: { deletingProject != nil },
                set: { if !$0 { deletingProject = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Elimina progetto", role: .destructive) {
                if let id = deletingProject {
                    confirmDeleteProject(id: id)
                }
                deletingProject = nil
            }
            Button("Annulla", role: .cancel) { deletingProject = nil }
        } message: {
            Text("Tutti i backend del progetto verranno rimossi. Quelli in esecuzione verranno prima fermati.")
        }
        .alert("Nuovo progetto", isPresented: $showNewProjectAlert) {
            TextField("Nome progetto", text: $newProjectName)
            Button("Crea") { confirmAddProject() }
            Button("Annulla", role: .cancel) {}
        } message: {
            if let newProjectError {
                Text(newProjectError)
            }
        }
    }

    /// Footer fisso della sidebar (Impostazioni + Aiuto): agganciato alla `List` tramite
    /// `.safeAreaInset(edge: .bottom)` invece di vivere DENTRO la lista, così resta ancorato
    /// in fondo alla sidebar indipendentemente dallo scroll del contenuto sopra — a differenza
    /// di una `Section` finale, che scrolla via insieme al resto quando i progetti sono tanti.
    /// `.thinMaterial` per staccarlo visivamente dal contenuto che gli scorre dietro (coerente
    /// con la vetrosità di altri pannelli fissi dell'app) invece di uno sfondo `.clear`, che si
    /// fonderebbe con l'ultima riga della lista e renderebbe meno leggibile il confine.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, 3)

            SettingsLink {
                sidebarFooterLabel(title: "Impostazioni", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Button {
                openWindow(id: "help")
            } label: {
                sidebarFooterLabel(title: "Aiuto", systemImage: "questionmark.circle")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(.thinMaterial)
    }

    /// Contenuto di una riga del footer: full-width e allineata a sinistra come le righe
    /// standard della sidebar, con padding verticale/orizzontale coerente con quelle generate
    /// da `List`/`Label` in stile `.sidebar`.
    private func sidebarFooterLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// Copia negli appunti il prompt pronto per Claude Code (Feature 2), poi conferma con un
    /// toast ("Prompt copiato"). Il bottone che lancia l'azione ora vive dentro il Menu
    /// "Aggiungi progetto": il menu si chiude non appena l'item viene selezionato, quindi una
    /// label transiente interna al bottone non sarebbe mai visibile — il toast è l'unico
    /// meccanismo di conferma che l'utente vede davvero.
    private func copyClaudeCodePrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ClaudeCodePrompt.make(), forType: .string)

        ToastCenter.shared.show("Prompt copiato", systemImage: "checkmark")
    }

    /// Bottone "Scansiona cartella…": NSOpenPanel diretto (stesso motivo delle altre sheet di
    /// questo file — `.fileImporter` da sheet modale è inaffidabile su macOS), poi delega
    /// l'esito a `onScanRequested` così la presentazione di `ScanResultsSheet` resta di
    /// competenza di `ContentView`.
    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Scegli la cartella del progetto da scansionare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = ProjectScanner.scan(root: url)
        onScanRequested(result, url)
    }

    /// Fallback (nessuno store, usato solo dai test/preview con AppModel legacy): tutte le
    /// righe condivise, invariato rispetto al comportamento pre-Phase D.
    @ViewBuilder
    private var navigationRowsFallback: some View {
        Label("Griglia", systemImage: "square.grid.2x2")
            .tag(SidebarSelection.grid)

        Label("Focus", systemImage: "rectangle.on.rectangle")
            .tag(SidebarSelection.focus)

        ForEach(model.services) { controller in
            serviceRow(for: controller, projectID: controller.config.projectName)
                .tag(SidebarSelection.service(controller.id))
        }
    }

    private func controllers(forProject project: StoredProject) -> [ServiceController] {
        model.services.filter { $0.config.projectName == project.name }
    }

    /// Riga progetto: `DisclosureGroup` per il chevron espandi/comprimi + i rigi servizio,
    /// ma la SELEZIONE della label non usa `.tag()` sulla label (o sul gruppo) — vedi nota
    /// sotto sul perché. La label è una `HStack` con `.contentShape(Rectangle())` +
    /// `.onTapGesture` che scrive direttamente il binding `selection`, indipendente dal
    /// meccanismo di tap del chevron (che resta di competenza esclusiva di `DisclosureGroup`
    /// tramite `isExpanded`).
    ///
    /// PERCHÉ non `.tag()`: sia taggare la label sia taggare l'intero `DisclosureGroup`
    /// compilano entrambi puliti con `swift build` (verificato), ma essendo impossibilitati a
    /// lanciare l'app per verifica manuale, e con regressioni note e documentate su macOS
    /// 14->15 di conflazione tra selezione-riga e hit-testing del chevron in
    /// `List(selection:)` + `DisclosureGroup`/`OutlineGroup` (rigo espandi/seleziona che si
    /// "rubano" il tap a seconda del punto esatto del click), si preferisce il pattern più
    /// robusto: gesture di selezione esplicita e disaccoppiata dal chevron. Vedi report per
    /// la variante alternativa (tag-based) considerata.
    private func projectDisclosureRow(_ project: StoredProject) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(forProjectID: project.id)) {
            ForEach(controllers(forProject: project)) { controller in
                serviceRow(for: controller, projectID: project.id)
                    .tag(SidebarSelection.service(controller.id))
            }

            Button {
                addingServiceToProject = project.id
            } label: {
                Label("Aggiungi backend", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .help("Aggiungi un nuovo backend a \"\(project.name)\"")
        } label: {
            HStack {
                if let accentColorHex = project.accentColorHex, let color = Color(hex: accentColorHex) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Label(project.name, systemImage: "folder")
                Spacer()
                let services = controllers(forProject: project)
                if !services.isEmpty {
                    let aliveCount = services.filter(\.processAlive).count
                    Text("\(aliveCount)/\(services.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: aliveCount)
                }
            }
            .contentShape(Rectangle())
            .listRowBackground(
                selection == .project(project.id)
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .onTapGesture {
                selection = .project(project.id)
            }
        }
    }

    /// Contenuto del menu contestuale sul rigo progetto: avvia/ferma (in cima, per accesso
    /// rapido), poi impostazioni/cambio cartella, poi export, poi elimina — in questo ordine
    /// esplicito per separare le azioni "frequenti" da quelle "distruttive/di configurazione".
    @ViewBuilder
    private func projectContextMenuContent(_ project: StoredProject) -> some View {
        let isRunning = controllers(forProject: project).contains { $0.processAlive }

        Button("Avvia progetto") {
            model.startProject(named: project.id)
            ToastCenter.shared.show("Avvio progetto \(project.name)", systemImage: "play.circle.fill")
        }
        .disabled(controllers(forProject: project).allSatisfy { $0.processAlive })

        Button("Ferma progetto") {
            model.stopProject(named: project.id)
            ToastCenter.shared.show("Arresto progetto \(project.name)", systemImage: "stop.circle.fill")
        }
        .disabled(!isRunning)

        Button("Riavvia progetto") {
            model.restartProject(named: project.id)
            ToastCenter.shared.show("Riavvio progetto \(project.name)", systemImage: "arrow.clockwise")
        }
        .disabled(!isRunning)

        Button("Pulisci terminali") {
            model.clearProjectTerminals(named: project.id)
            ToastCenter.shared.show("Terminali di \(project.name) puliti", systemImage: "clear")
        }

        Divider()

        Button("Impostazioni progetto…") {
            settingsProject = project.id
        }

        Button("Cambia cartella radice…") {
            rebasingProject = project.id
        }

        Button("Esporta progetto…") {
            exportingProject = project.id
        }

        Divider()

        Button("Elimina progetto", role: .destructive) {
            deletingProject = project.id
        }
    }

    /// `projectID` è l'id reale del progetto (da `StoredProject.id`, passato esplicitamente
    /// dal chiamante) — NON derivato da `controller.config.projectName`, che è il nome
    /// leggibile del progetto e coincide con l'id solo perché `StoredProject.id == name`.
    /// Nel fallback legacy (nessuno store) i due valori restano equivalenti, quindi il
    /// comportamento per quel percorso non cambia.
    private func serviceRow(for controller: ServiceController, projectID: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(status: controller.status)
                .scaleEffect(0.75)
            Image(systemName: controller.config.symbolName ?? "server.rack")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(controller.config.displayName)
            if model.pendingConfigChanges.contains(controller.id) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Modifiche in sospeso: ferma il backend per applicarle")
            }
            Spacer()
            // Stessa condizione (cheap, a render time) del badge sulla card: qui è solo un
            // indicatore — la creazione guidata si apre dal badge cliccabile sulla card.
            if !controller.config.envBadgeDisabled,
               EnvFileWriter.envFileMissing(in: controller.config.workingDirectory) {
                Image(systemName: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("File .env mancante — clicca il badge sulla card per crearlo")
                    .accessibilityLabel("File .env mancante")
            }
            if controller.logs.errorCount > 0 {
                Text("\(controller.logs.errorCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: controller.logs.errorCount)
                    .accessibilityLabel("\(controller.logs.errorCount) errori nei log")
            }
        }
        .contextMenu {
            Button("Modifica…") {
                editingService = (projectID, controller.config.name)
            }
            .disabled(controller.processAlive)
            .help(controller.processAlive ? "Ferma il backend per modificarlo" : "")

            Button("Elimina", role: .destructive) {
                deletingService = (projectID, controller.config.name)
            }
        }
    }

    private func confirmDeleteService(projectID: String, name: String) {
        guard let store = model.store else { return }
        if let controller = model.services.first(where: {
            $0.config.projectName == projectID && $0.config.name == name
        }), controller.processAlive {
            controller.stop()
        }
        store.removeService(named: name, fromProject: projectID)
        model.reloadFromStore()
    }

    private func confirmDeleteProject(id: String) {
        guard let store = model.store else { return }
        for controller in model.services where controller.config.projectName == id && controller.processAlive {
            controller.stop()
        }
        store.removeProject(id: id)
        model.reloadFromStore()
    }

    /// Esito del `.fileImporter` di "Cambia cartella radice…": ribasa il progetto in
    /// `rebasingProject` sulla cartella scelta. Errori (es. progetto sparito nel frattempo)
    /// finiscono in `rebaseError`, mostrato da un alert dedicato invece di fallire silenziosamente.
    private func handleRebasePick(_ result: Result<URL, Error>) {
        guard let projectID = rebasingProject else { return }
        rebasingProject = nil
        guard let store = model.store else { return }
        switch result {
        case .failure:
            rebaseError = "Impossibile aprire il selettore file. Riprova."
        case .success(let url):
            do {
                try store.rebaseProject(id: projectID, ontoRoot: url)
                model.reloadFromStore()
                ToastCenter.shared.show("Percorsi aggiornati", systemImage: "checkmark.circle.fill")
            } catch {
                rebaseError = error.localizedDescription
            }
        }
    }

    private func confirmAddProject() {
        guard let store = model.store else { return }
        do {
            try store.addProject(named: newProjectName)
            model.reloadFromStore()
            newProjectError = nil
        } catch {
            newProjectError = error.localizedDescription
            // Ripresenta l'alert per mostrare l'errore invece di chiuderlo silenziosamente.
            showNewProjectAlert = true
        }
    }
}

/// Wrapper `Identifiable` per pilotare `.sheet(item:)` con un `String?` opzionale (project id).
private struct SheetProjectID: Identifiable {
    let id: String
}

/// Wrapper `Identifiable` per pilotare `.sheet(item:)` con la coppia (progetto, nome originale)
/// del servizio in modifica.
private struct SheetEditTarget: Identifiable {
    let projectID: String
    let originalName: String
    var id: String { "\(projectID)/\(originalName)" }
}

/// Sheet minimale di export: chiede la root rispetto a cui rendere relative le directory dei
/// servizi (default = genitore comune calcolato da `ProjectTemplateCodec.commonRoot`, fallback
/// home dell'utente), poi scrive `<nome progetto>.blauncher.json` via `.fileExporter`.
private struct ExportTemplateSheet: View {
    var model: AppModel
    var projectID: String
    var onDismiss: () -> Void

    @State private var rootURL: URL?
    @State private var showFileExporter = false
    @State private var exportDocument: TemplateJSONDocument?
    @State private var errorMessage: String?

    private var project: StoredProject? {
        model.store?.projects.first { $0.id == projectID }
    }

    private var suggestedFileName: String {
        (project?.name ?? "progetto") + ".blauncher.json"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Esporta template").font(.title2.weight(.semibold))

            if let project {
                Text("Progetto \"\(project.name)\" — \(project.services.count) backend")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Root del progetto").font(.headline)
                Text("Le cartelle dei backend verranno salvate come path relativi a questa root, così chi importa il template può ribasarle sul proprio Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(rootURL?.path ?? "Nessuna cartella selezionata")
                        .font(.callout)
                        .foregroundStyle(rootURL == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Scegli…") { chooseExportRoot() }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Esporta…") { prepareExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rootURL == nil || project == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: prefillDefaultRoot)
        .fileExporter(isPresented: $showFileExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: suggestedFileName) { result in
            switch result {
            case .success:
                ToastCenter.shared.show("Template esportato", systemImage: "square.and.arrow.up")
                onDismiss()
            case .failure:
                errorMessage = "Esportazione non riuscita. Controlla i permessi della cartella di destinazione."
            }
        }
    }

    /// Default proposto: genitore comune delle directory dei servizi del progetto, calcolato
    /// da `ProjectTemplateCodec.commonRoot`; se non calcolabile (servizi senza antenato comune,
    /// o progetto senza servizi), ricade sulla home dell'utente.
    /// NSOpenPanel diretto: `.fileImporter` da una sheet modale è inaffidabile su macOS.
    private func chooseExportRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Scegli la cartella radice rispetto a cui salvare i percorsi"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL = url
    }

    private func prefillDefaultRoot() {
        guard rootURL == nil else { return }
        let directories = project?.services.map(\.directory) ?? []
        rootURL = ProjectTemplateCodec.commonRoot(forServiceDirectories: directories)
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func prepareExport() {
        guard let store = model.store, let rootURL else { return }
        do {
            let data = try store.exportTemplate(projectID: projectID, root: rootURL)
            exportDocument = TemplateJSONDocument(data: data)
            showFileExporter = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
