import SwiftUI

/// Card glass di un backend: stato, controlli, terminale espandibile.
struct ServiceCardView: View {
    var controller: ServiceController
    @State private var showTerminal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatusDot(status: controller.status)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.config.displayName)
                            .font(.headline)

                        if controller.logs.errorCount > 0 {
                            Text("\(controller.logs.errorCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.85), in: .capsule)
                                .foregroundStyle(.white)
                                .help("Errori nei log di questa esecuzione")
                        }
                    }
                    HStack(spacing: 4) {
                        Text(controller.config.port.map { "porta \(String($0))" } ?? "via NATS")
                        Text("·")
                        Text(controller.status.label)
                            .foregroundStyle(controller.status.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let startedAt = controller.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                controlButtons

                Button {
                    withAnimation(.snappy) { showTerminal.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showTerminal ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help(showTerminal ? "Nascondi terminale" : "Mostra terminale")
            }
            .padding(14)

            if showTerminal {
                TerminalView(logs: controller.logs)
                    .frame(height: 300)
                    .padding([.horizontal, .bottom], 14)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        .imageScale(.medium)
    }
}
