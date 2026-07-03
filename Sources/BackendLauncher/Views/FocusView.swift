import SwiftUI

/// Pagina "Focus": terminali grandi affiancati per i backend scelti dall'utente.
struct FocusView: View {
    var model: AppModel
    @AppStorage("focusServices") private var focusServicesRaw = "gateway,id"

    private var selectedNames: Set<String> {
        FocusSelection.parse(focusServicesRaw)
    }

    private var selectedControllers: [ServiceController] {
        model.services.filter { selectedNames.contains($0.config.name) }
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
        let isSelected = selectedNames.contains(controller.config.name)
        return Button {
            toggle(controller.config.name)
        } label: {
            HStack(spacing: 6) {
                StatusDot(status: controller.status)
                    .scaleEffect(0.7)
                Text(controller.config.displayName)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.4)) : .regular, in: .capsule)
    }

    private func toggle(_ name: String) {
        var names = selectedNames
        if names.contains(name) {
            names.remove(name)
        } else {
            names.insert(name)
        }
        focusServicesRaw = FocusSelection.serialize(names, ordering: model.services.map(\.config.name))
    }

    @ViewBuilder
    private var panes: some View {
        let controllers = selectedControllers
        switch controllers.count {
        case 0:
            ContentUnavailableView("Seleziona uno o più backend",
                                   systemImage: "rectangle.on.rectangle")
        case 1:
            FocusPane(controller: controllers[0])
        case 2:
            HStack(spacing: 14) {
                ForEach(controllers) { controller in
                    FocusPane(controller: controller)
                }
            }
        default:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    ForEach(controllers) { controller in
                        FocusPane(controller: controller)
                            .frame(minHeight: 380)
                    }
                }
            }
        }
    }
}

/// Riquadro glass di un singolo backend in Focus: header compatto + terminale a pieno spazio.
private struct FocusPane: View {
    var controller: ServiceController

    var body: some View {
        VStack(spacing: 8) {
            header
            TerminalView(logs: controller.logs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var header: some View {
        let status = controller.status
        return HStack(spacing: 10) {
            StatusDot(status: status)

            Text(controller.config.displayName)
                .font(.headline)

            Text(status.label)
                .font(.caption)
                .foregroundStyle(status.color)

            if let startedAt = controller.startedAt {
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let stats = controller.stats, controller.processAlive {
                Text("CPU \(stats.cpuPercent, specifier: "%.0f")% · \(stats.rssMB, specifier: "%.0f") MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

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
enum FocusSelection {
    static func parse(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Serializza rispettando l'ordine fornito in `ordering` (tipicamente l'ordine di ServiceConfig.all),
    /// scartando nomi non presenti in `ordering`.
    static func serialize(_ names: Set<String>, ordering: [String]) -> String {
        ordering.filter { names.contains($0) }.joined(separator: ",")
    }
}
