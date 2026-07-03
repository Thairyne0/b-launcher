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

    private var process: SpawnedProcess?
    private var stopRequested = false
    private var lastExitCode: Int32?
    private var pendingRestart = false
    private let cwdOverride: String?

    /// `cwd` iniettabile solo per i test; in produzione usa config.workingDirectory.
    init(config: ServiceConfig, cwd: String? = nil) {
        self.config = config
        self.cwdOverride = cwd
    }

    nonisolated var id: String { config.id }

    var processID: pid_t? { processAlive ? process?.pid : nil }

    var status: ServiceStatus {
        ServiceStatus.derive(processAlive: processAlive, portOpen: portOpen,
                             stopRequested: stopRequested, lastExitCode: lastExitCode)
    }

    func start() {
        guard !processAlive else { return }
        guard status != .external else {
            logs.ingest("[launcher] porta \(config.port) già occupata da un processo esterno — avvio rifiutato\n")
            return
        }
        stopRequested = false
        lastExitCode = nil
        logs.ingest("[launcher] ── avvio \(config.displayName) (\(config.command)) ──\n")
        do {
            let cwd = cwdOverride ?? config.workingDirectory.path
            process = try SpawnedProcess(
                shellCommand: "exec \(config.command)",
                cwd: cwd,
                onChunk: { [weak self] chunk in self?.logs.ingest(chunk) },
                onExit: { [weak self] code in self?.handleExit(code) }
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
        logs.flushPartial()
        logs.ingest("[launcher] ── processo terminato (exit \(code)) ──\n")
        if pendingRestart {
            pendingRestart = false
            start()
        }
    }
}
