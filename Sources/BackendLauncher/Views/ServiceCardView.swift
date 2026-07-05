import AppKit
import SwiftUI

/// Card glass di un backend: stato, controlli, terminale espandibile.
struct ServiceCardView: View {
    var controller: ServiceController
    @Binding var showTerminal: Bool
    @State private var showEnvSheet = false
    /// Chi occupa la porta quando il servizio è "esterno" (blu): risolto via `lsof` fuori
    /// dal MainActor. `nil` = non ancora risolto o non applicabile.
    @State private var portOwner: String?

    private var readinessCaption: String {
        switch controller.config.readiness {
        case .tcpPort(let p): "porta \(p)"
        case .logMarker: "via log"
        case .processAlive: "sempre pronto"
        case .httpHealth(let p, let path): "health :\(p)\(path)"
        }
    }

    /// Vero se la working directory del servizio non esiste su disco. Controllo cheap
    /// (una singola stat) fatto a render time: nessuna cache necessaria, la UI si
    /// aggiorna da sola alla prossima ridisegno se la cartella compare/sparisce.
    private var directoryIsMissing: Bool {
        !FileManager.default.fileExists(atPath: controller.config.workingDirectory.path)
    }

    /// Vero se la working directory esiste ma non contiene `.env` (backend appena clonato).
    /// Stesso pattern cheap a render time di `directoryIsMissing`: una `stat`, nessuna cache —
    /// il badge sparisce da solo al primo ridisegno dopo la creazione del file.
    private var envFileIsMissing: Bool {
        !controller.config.envBadgeDisabled
            && EnvFileWriter.envFileMissing(in: controller.config.workingDirectory)
    }

    /// Colore accento del progetto proprietario, se impostato e valido — usato solo per il
    /// bordo sottile sopra il glass (feature "colore progetto").
    private var accentColor: Color? {
        controller.config.accentColorHex.flatMap(Color.init(hex:))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatusDot(status: controller.status)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: controller.config.symbolName ?? "server.rack")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Text(controller.config.displayName)
                            .font(.title3.weight(.semibold))

                        if controller.logs.errorCount > 0 {
                            Button {
                                controller.logs.levelFilter = .errors
                                withAnimation(.snappy) { showTerminal = true }
                            } label: {
                                Text("\(controller.logs.errorCount)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 1)
                                    .background(Color.red.opacity(0.85), in: .capsule)
                                    .foregroundStyle(.white)
                                    .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
                                    .contentTransition(.numericText())
                                    .animation(.snappy, value: controller.logs.errorCount)
                            }
                            .buttonStyle(.plain)
                            .help("Mostra gli errori nel terminale")
                            .accessibilityLabel("\(controller.logs.errorCount) errori nei log")
                        }
                    }
                    HStack(spacing: 4) {
                        Text(readinessCaption)
                        Text("·")
                        Text(controller.status.label)
                            .foregroundStyle(controller.status.color)
                        if let branch = controller.gitBranch {
                            Text("·")
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .foregroundStyle(controller.gitBranchMismatch ? Color.orange : Color.secondary)
                                .help(controller.gitBranchMismatch
                                      ? "Branch diverso dagli altri backend del progetto"
                                      : "Branch git della cartella")
                        }
                        if controller.status == .starting, let startedAt = controller.startedAt {
                            startupTimer(since: startedAt)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if directoryIsMissing {
                        Label("cartella mancante", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .help(controller.config.workingDirectory.path)
                    }

                    if controller.status == .external, let portOwner {
                        Label("porta occupata da: \(portOwner)", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .help("Un processo esterno al launcher tiene la porta \(controller.config.port.map(String.init) ?? "?"). Fermalo per poter avviare questo backend.")
                            .textSelection(.enabled)
                    }

                    if envFileIsMissing {
                        Button {
                            showEnvSheet = true
                        } label: {
                            Label(".env mancante — crealo", systemImage: "key.slash")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Nessun file .env in \(controller.config.workingDirectory.path) — clicca per incollarne il contenuto e crearlo")
                        .accessibilityLabel("File .env mancante per \(controller.config.displayName), clicca per crearlo")
                    }

                    if !showTerminal && controller.processAlive {
                        Text(controller.logs.lines.last?.text ?? " ")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                if let startedAt = controller.startedAt {
                    MetricPill(icon: "clock", accessibilityLabel: "Uptime: in esecuzione da \(startedAt.formatted(date: .omitted, time: .standard))") {
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    }
                }

                if let stats = controller.stats, controller.processAlive {
                    MetricPill(icon: "gauge.with.dots.needle.33percent",
                               accessibilityLabel: "CPU e memoria: \(Int(stats.cpuPercent)) per cento, \(Int(stats.rssMB)) megabyte") {
                        Text("\(stats.cpuPercent, specifier: "%.0f")% · \(stats.rssMB, specifier: "%.0f") MB")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: stats.cpuPercent)
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { showTerminal.toggle() }
            }

            if showTerminal {
                TerminalView(logs: controller.logs)
                    .frame(height: 400)
                    .padding([.horizontal, .bottom], 16)
            }
        }
        .sheet(isPresented: $showEnvSheet) {
            EnvCreateSheet(serviceName: controller.config.displayName,
                           directory: controller.config.workingDirectory)
        }
        // Risolvi il proprietario della porta quando (e solo quando) il servizio è esterno.
        // `lsof` è bloccante: fuori dal MainActor. Si ricalcola a ogni transizione di stato.
        .task(id: controller.status) {
            guard controller.status == .external, let port = controller.config.port else {
                portOwner = nil
                return
            }
            portOwner = await Task.detached(priority: .utility) {
                PortOwner.describe(port: port)
            }.value
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay {
            if let accentColor {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(accentColor.opacity(0.5), lineWidth: 1.5)
            }
        }
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
            Button("Apri log nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([controller.logFileURL])
            }
            Button("Apri Terminale qui") {
                openTerminal(at: controller.config.workingDirectory)
            }
        }
    }

    /// Apre Terminal.app sulla working directory del servizio. Preferisce la lookup via
    /// bundle identifier (`urlForApplication(withBundleIdentifier:)`, robusta a spostamenti
    /// di Terminal.app), con fallback ai path noti se per qualche motivo il bundle non
    /// risulta registrato a Launch Services.
    private func openTerminal(at directory: URL) {
        let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"]
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let terminalURL else { return }
        NSWorkspace.shared.open([directory], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Timer di avvio mostrato mentre lo stato è `.starting`: "avvio da" + un `Text(.timer)`
    /// che si auto-aggiorna senza bisogno di un `Task`/poller dedicato. L'eventuale hint
    /// "lento? guarda i log" (oltre i 90s) è invece calcolato dentro un `TimelineView`
    /// periodico: `Text(.timer)` si ridisegna da solo ma non ci dà un hook per leggere il
    /// tempo trascorso, quindi il controllo soglia ha bisogno di un proprio trigger periodico.
    @ViewBuilder
    private func startupTimer(since startedAt: Date) -> some View {
        Text("· avvio da \(startedAt, style: .timer)")
            .monospacedDigit()

        TimelineView(.periodic(from: .now, by: 30)) { context in
            if context.date.timeIntervalSince(startedAt) > 90 {
                Text("· lento? guarda i log")
                    .foregroundStyle(.orange)
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
            .disabled(controller.processAlive || status == .external || directoryIsMissing)
            .foregroundStyle(controller.processAlive || status == .external || directoryIsMissing ? Color.secondary : Color.green)
            .padding(4)
            .help(directoryIsMissing ? "Cartella mancante: impossibile avviare" : "Avvia")

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
