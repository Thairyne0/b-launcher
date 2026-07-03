import AppKit
import SwiftUI

/// Card glass di un backend: stato, controlli, terminale espandibile.
struct ServiceCardView: View {
    var controller: ServiceController
    @Binding var showTerminal: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatusDot(status: controller.status)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.config.displayName)
                            .font(.title3.weight(.semibold))

                        if controller.logs.errorCount > 0 {
                            Text("\(controller.logs.errorCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.85), in: .capsule)
                                .foregroundStyle(.white)
                                .help("Errori nei log di questa esecuzione")
                                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
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

                Button {
                    withAnimation(.snappy) { showTerminal.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showTerminal ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .padding(4)
                .help(showTerminal ? "Nascondi terminale" : "Mostra terminale")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            if showTerminal {
                TerminalView(logs: controller.logs)
                    .frame(height: 400)
                    .padding([.horizontal, .bottom], 16)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contextMenu {
            Button("Apri directory nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([controller.config.workingDirectory])
            }
            if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                Button("Apri in VS Code") {
                    NSWorkspace.shared.open([controller.config.workingDirectory],
                                            withApplicationAt: vscode,
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Button("Copia percorso") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(controller.config.workingDirectory.path, forType: .string)
            }
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
            .foregroundStyle(controller.processAlive || status == .external ? Color.secondary : Color.green)
            .padding(4)
            .help("Avvia")

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!controller.processAlive || status == .stopping)
            .foregroundStyle(!controller.processAlive || status == .stopping ? Color.secondary : Color.red)
            .padding(4)
            .help("Ferma")

            Button {
                controller.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(status == .external || status == .stopping)
            .padding(4)
            .help("Riavvia")
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }
}
