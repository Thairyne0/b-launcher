import SwiftUI

/// Selezione corrente nella sidebar: griglia completa, vista Focus, o singolo servizio.
enum SidebarSelection: Hashable {
    case grid
    case focus
    case service(String)
}

/// Serializzazione pura `SidebarSelection` <-> stringa per @AppStorage ("grid" / "focus" / "service:<id>").
enum SidebarSelectionCoding {
    private static let servicePrefix = "service:"

    static func encode(_ selection: SidebarSelection) -> String {
        switch selection {
        case .grid: return "grid"
        case .focus: return "focus"
        case .service(let id): return servicePrefix + id
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

    /// `List(selection:)` richiede un binding opzionale; un deselect (nil) ricade su `.grid`
    /// così la vista di dettaglio ha sempre una selezione valida.
    private var listSelection: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selection = $0 ?? .grid }
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

                ForEach(projects) { project in
                    Section {
                        ForEach(controllers(forProject: project)) { controller in
                            serviceRow(for: controller)
                                .tag(SidebarSelection.service(controller.id))
                        }

                        Button {
                            addingServiceToProject = project.id
                        } label: {
                            Label("Aggiungi backend", systemImage: "plus")
                        }
                        .help("Aggiungi un nuovo backend a \"\(project.name)\"")
                    } header: {
                        Text(project.name)
                    }
                    .contextMenu {
                        Button("Elimina progetto", role: .destructive) {
                            deletingProject = project.id
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
            serviceRow(for: controller)
                .tag(SidebarSelection.service(controller.id))
        }
    }

    private func controllers(forProject project: StoredProject) -> [ServiceController] {
        model.services.filter { $0.config.projectName == project.name }
    }

    private func serviceRow(for controller: ServiceController) -> some View {
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
                editingService = (controller.config.projectName, controller.config.name)
            }
            .disabled(controller.processAlive)
            .help(controller.processAlive ? "Ferma il servizio per modificarlo" : "")

            Button("Elimina", role: .destructive) {
                deletingService = (controller.config.projectName, controller.config.name)
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
