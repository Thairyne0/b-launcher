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

    @State private var addingServiceToProject: String?
    @State private var editingService: (projectID: String, originalName: String)?
    @State private var deletingService: (projectID: String, name: String)?
    @State private var deletingProject: String?
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var newProjectError: String?
    @State private var exportingProject: String?
    @State private var showImportSheet = false
    /// Progetti collassati (per id) — set vuoto di default: TUTTI i progetti partono espansi
    /// senza dover pre-popolare nulla da `projects` (evita di dover reagire a progetti nuovi).
    @State private var collapsedProjects: Set<String> = []

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
                                Button("Esporta progetto…") {
                                    exportingProject = project.id
                                }
                                Button("Elimina progetto", role: .destructive) {
                                    deletingProject = project.id
                                }
                            }
                    }
                }
            } else {
                Section {
                    navigationRowsFallback
                }
            }

            Section {
                Button {
                    newProjectName = ""
                    newProjectError = nil
                    showNewProjectAlert = true
                } label: {
                    Label("Nuovo progetto", systemImage: "plus")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label("Importa progetto…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .listStyle(.sidebar)
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
                Label(project.name, systemImage: "folder")
                Spacer()
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

    /// `projectID` è l'id reale del progetto (da `StoredProject.id`, passato esplicitamente
    /// dal chiamante) — NON derivato da `controller.config.projectName`, che è il nome
    /// leggibile del progetto e coincide con l'id solo perché `StoredProject.id == name`.
    /// Nel fallback legacy (nessuno store) i due valori restano equivalenti, quindi il
    /// comportamento per quel percorso non cambia.
    private func serviceRow(for controller: ServiceController, projectID: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(status: controller.status)
                .scaleEffect(0.75)
            Text(controller.config.displayName)
            if model.pendingConfigChanges.contains(controller.id) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .help("Modifiche in sospeso: ferma il servizio per applicarle")
            }
            Spacer()
            if controller.logs.errorCount > 0 {
                Text("\(controller.logs.errorCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white)
            }
        }
        .contextMenu {
            Button("Modifica…") {
                editingService = (projectID, controller.config.name)
            }
            .disabled(controller.processAlive)
            .help(controller.processAlive ? "Ferma il servizio per modificarlo" : "")

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
    @State private var showRootPicker = false
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
                    Button("Scegli…") { showRootPicker = true }
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
        .fileImporter(isPresented: $showRootPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            rootURL = url
        }
        .fileExporter(isPresented: $showFileExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: suggestedFileName) { result in
            switch result {
            case .success:
                onDismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Default proposto: genitore comune delle directory dei servizi del progetto, calcolato
    /// da `ProjectTemplateCodec.commonRoot`; se non calcolabile (servizi senza antenato comune,
    /// o progetto senza servizi), ricade sulla home dell'utente.
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
