import SwiftUI

/// Pagina "Focus": terminali grandi affiancati per i backend scelti dall'utente.
struct FocusView: View {
    var model: AppModel
    @AppStorage("focusServices") private var focusServicesRaw = "gateway,id"

    /// Id (namespaced) selezionati, migrando al volo eventuali token "vecchio stile"
    /// (bare name senza "/", salvati prima del namespacing) verso l'id univoco corrispondente.
    private var selectedIDs: Set<String> {
        FocusSelection.migrate(FocusSelection.parse(focusServicesRaw), services: model.services.map(\.config))
    }

    private var selectedControllers: [ServiceController] {
        model.services.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 14) {
            chipBar

            panes
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.services) { controller in
                        chip(for: controller)
                    }
                }
            }
        }
    }

    private func chip(for controller: ServiceController) -> some View {
        let isSelected = selectedIDs.contains(controller.id)
        return Button {
            toggle(controller.id)
        } label: {
            HStack(spacing: 6) {
                StatusDot(status: controller.status)
                    .scaleEffect(0.7)
                Text(controller.config.displayName)
                    .font(.caption.weight(.medium))
                if controller.logs.errorCount > 0 {
                    Text("\(controller.logs.errorCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.85), in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fontWeight(isSelected ? .medium : nil)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.4)) : .regular, in: .capsule)
    }

    private func toggle(_ id: String) {
        var ids = selectedIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        // Riserializza sempre in id namespaced pieni: dopo il primo toggle la persistenza
        // "vecchio stile" (bare name) è completamente migrata.
        focusServicesRaw = FocusSelection.serialize(ids, ordering: model.services.map(\.id))
    }

    @ViewBuilder
    private var panes: some View {
        let controllers = selectedControllers
        switch controllers.count {
        case 0:
            ContentUnavailableView("Seleziona uno o più backend",
                                   systemImage: "rectangle.on.rectangle")
        case 1:
            ServicePaneView(controller: controllers[0])
        case 2:
            HStack(spacing: 14) {
                ForEach(controllers) { controller in
                    ServicePaneView(controller: controller)
                }
            }
        default:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    ForEach(controllers) { controller in
                        ServicePaneView(controller: controller)
                            .frame(minHeight: 380)
                    }
                }
            }
        }
    }
}

/// Riquadro glass di un singolo backend: header compatto + terminale a pieno spazio.
/// Usato dalla griglia Focus (multi-pane) e dalla vista di dettaglio singolo servizio in sidebar.
struct ServicePaneView: View {
    var controller: ServiceController

    var body: some View {
        VStack(spacing: 8) {
            header
            TerminalView(logs: controller.logs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var header: some View {
        let status = controller.status
        return HStack(spacing: 10) {
            StatusDot(status: status)

            Image(systemName: controller.config.symbolName ?? "server.rack")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(controller.config.displayName)
                .font(.title3.weight(.semibold))

            Text(status.label)
                .font(.caption)
                .foregroundStyle(status.color)

            Spacer()

            if let startedAt = controller.startedAt {
                MetricPill(icon: "clock") {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                }
            }

            if let stats = controller.stats, controller.processAlive {
                MetricPill(icon: "gauge.with.dots.needle.33percent") {
                    Text("\(stats.cpuPercent, specifier: "%.0f")% · \(stats.rssMB, specifier: "%.0f") MB")
                        .monospacedDigit()
                }
            }

            controlButtons
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        let status = controller.status
        HStack(spacing: 8) {
            Button {
                controller.start()
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(controller.processAlive || status == .external)
            .help("Avvia")

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!controller.processAlive || status == .stopping)
            .help("Ferma")

            Button {
                controller.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(status == .external || status == .stopping)
            .help("Riavvia")
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
    }
}

/// Serializzazione pura Set<String> <-> stringa CSV per @AppStorage, con ordine stabile.
/// Storicamente i token erano nomi brevi ("gateway"); dal namespacing multi-progetto
/// (Phase D) i token persistiti sono id pieni ("Progetto/gateway"). `migrate` fa da ponte.
enum FocusSelection {
    static func parse(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Serializza rispettando l'ordine fornito in `ordering` (tipicamente l'ordine dei
    /// servizi correnti), scartando token non presenti in `ordering`.
    static func serialize(_ names: Set<String>, ordering: [String]) -> String {
        ordering.filter { names.contains($0) }.joined(separator: ",")
    }

    /// Migra un set di token grezzi (misto vecchio-stile bare-name / nuovo-stile id pieno)
    /// verso id namespaced pieni, dato l'elenco dei servizi correnti.
    /// - Un token che contiene "/" è già un id pieno: passa così com'è (anche se non
    ///   corrisponde più a nessun servizio corrente — verrà scartato a valle dal filtro).
    /// - Un token senza "/" (bare name storico) viene risolto sull'unico servizio il cui
    ///   `config.name` corrisponde; se ambiguo (più progetti con lo stesso nome breve) o
    ///   assente, il token viene silenziosamente scartato (non c'è modo sicuro di scegliere).
    static func migrate(_ tokens: Set<String>, services: [ServiceConfig]) -> Set<String> {
        var result: Set<String> = []
        for token in tokens {
            if token.contains("/") {
                result.insert(token)
            } else {
                let matches = services.filter { $0.name == token }
                if matches.count == 1 {
                    result.insert(matches[0].id)
                }
                // ambiguo o assente: scartato
            }
        }
        return result
    }
}
