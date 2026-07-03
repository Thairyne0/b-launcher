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

/// Sidebar del progetto: griglia, Focus, e un rigo per servizio con stato live.
struct SidebarView: View {
    var model: AppModel
    @Binding var selection: SidebarSelection

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
                ForEach(projects) { project in
                    Section(project.name) {
                        navigationRows
                    }
                }
            } else {
                Section {
                    navigationRows
                }
            }

            Section {
                Button {
                    // In arrivo — fase wizard (Phase D)
                } label: {
                    Label("Aggiungi backend", systemImage: "plus")
                }
                .disabled(true)
                .help("In arrivo — fase wizard")

                Button {
                    // In arrivo — fase wizard (Phase D)
                } label: {
                    Label("Nuovo progetto", systemImage: "plus")
                }
                .disabled(true)
                .help("In arrivo — fase wizard")
            }
        }
        .listStyle(.sidebar)
    }

    /// Righe di navigazione condivise tra sezione per-progetto e fallback senza store:
    /// derivate da `model.services` (controller live) così stato/badge sono sempre aggiornati.
    @ViewBuilder
    private var navigationRows: some View {
        Label("Griglia", systemImage: "square.grid.2x2")
            .tag(SidebarSelection.grid)

        Label("Focus", systemImage: "rectangle.on.rectangle")
            .tag(SidebarSelection.focus)

        ForEach(model.services) { controller in
            serviceRow(for: controller)
                .tag(SidebarSelection.service(controller.id))
        }
    }

    private func serviceRow(for controller: ServiceController) -> some View {
        HStack(spacing: 8) {
            StatusDot(status: controller.status)
                .scaleEffect(0.75)
            Text(controller.config.displayName)
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
    }
}
