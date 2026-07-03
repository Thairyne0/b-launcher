import Foundation
import Observation

/// Stato + azioni di un singolo backend. Vive su MainActor; i callback di
/// SpawnedProcess arrivano sulla main queue.
@MainActor
@Observable
final class ServiceController: Identifiable {
    let config: ServiceConfig
    let logs = LogStore()

    private(set) var processAlive = false
    private(set) var startedAt: Date?
    var portOpen = false  // aggiornato dal poller di AppModel

    // servizi solo-NATS: pronto quando il log Nest annuncia l'avvio
    private(set) var readyMarkerSeen = false

    private static let readyMarker = "successfully started"

    private var process: SpawnedProcess?
    private var stopRequested = false
    private var lastExitCode: Int32?
    private var pendingRestart = false
    /// Generazione dello spawn corrente. EOF della pipe ed exit del processo sono eventi
    /// kernel indipendenti: dopo un restart un chunk bufferizzato (o un exit in ritardo)
    /// del VECCHIO processo può arrivare quando il NUOVO è già partito — va scartato.
    private var epoch = 0
    private let cwdOverride: String?

    /// `cwd` iniettabile solo per i test; in produzione usa config.workingDirectory.
    init(config: ServiceConfig, cwd: String? = nil) {
        self.config = config
        self.cwdOverride = cwd
    }

    nonisolated var id: String { config.id }

    var processID: pid_t? { processAlive ? process?.pid : nil }

    var status: ServiceStatus {
        // Per i servizi HTTP la prontezza è la porta aperta; per quelli solo-NATS
        // è il marker nei log. Il segnale confluisce nello stesso ingresso di derive.
        let ready = config.port != nil ? portOpen : readyMarkerSeen
        return ServiceStatus.derive(processAlive: processAlive, portOpen: ready,
                                    stopRequested: stopRequested, lastExitCode: lastExitCode)
    }

    func start() {
        guard !processAlive else { return }
        guard status != .external else {
            logs.ingest("[launcher] porta \(config.port.map(String.init) ?? "?") già occupata da un processo esterno — avvio rifiutato\n")
            return
        }
        stopRequested = false
        lastExitCode = nil
        readyMarkerSeen = false
        logs.ingest("[launcher] ── avvio \(config.displayName) (\(config.command)) ──\n")
        epoch += 1
        let myEpoch = epoch
        do {
            let cwd = cwdOverride ?? config.workingDirectory.path
            process = try SpawnedProcess(
                shellCommand: "exec \(config.command)",
                cwd: cwd,
                onChunk: { [weak self] chunk in
                    guard let self, self.epoch == myEpoch else { return }
                    if !self.readyMarkerSeen, chunk.localizedCaseInsensitiveContains(Self.readyMarker) {
                        self.readyMarkerSeen = true
                    }
                    self.logs.ingest(chunk)
                },
                onExit: { [weak self] code in
                    guard let self, self.epoch == myEpoch else { return }
                    self.handleExit(code)
                }
            )
            processAlive = true
            startedAt = Date()
        } catch {
            logs.ingest("[launcher] errore avvio: \(error.localizedDescription)\n")
            lastExitCode = -1
        }
    }

    func stop() {
        guard processAlive, let process else { return }
        stopRequested = true
        logs.ingest("[launcher] ── stop richiesto ──\n")
        process.terminate()
    }

    func restart() {
        if processAlive {
            pendingRestart = true
            stop()
        } else {
            start()
        }
    }

    private func handleExit(_ code: Int32) {
        processAlive = false
        process = nil
        startedAt = nil
        lastExitCode = code
        readyMarkerSeen = false
        logs.flushPartial()
        logs.ingest("[launcher] ── processo terminato (exit \(code)) ──\n")
        if pendingRestart {
            pendingRestart = false
            start()
        }
    }
}
