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

    /// Statistiche CPU/RAM del process group corrente (nil finché non c'è una seconda lettura).
    private(set) var stats: ProcessStats.Sample?
    private var statsTask: Task<Void, Never>?
    private var lastCPUSeconds: Double?

    // servizi con readiness .logMarker: pronto quando il log annuncia l'avvio
    private(set) var readyMarkerSeen = false

    private var process: SpawnedProcess?
    private var stopRequested = false
    private var lastExitCode: Int32?
    private var pendingRestart = false
    /// Generazione dello spawn corrente. EOF della pipe ed exit del processo sono eventi
    /// kernel indipendenti: dopo un restart un chunk bufferizzato (o un exit in ritardo)
    /// del VECCHIO processo può arrivare quando il NUOVO è già partito — va scartato.
    private var epoch = 0
    private let cwdOverride: String?
    private let onCrash: ((String, Int32) -> Void)?
    private let fileWriter: LogFileWriter

    /// Directory di default per i log di test: mai la vera ~/Library/Logs, per non
    /// inquinarla con gli innumerevoli ServiceController "fake" creati dalla test suite.
    private static let testLogDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blauncher-tests")

    /// `cwd` iniettabile solo per i test; in produzione usa config.workingDirectory.
    /// `onCrash` notifica (nome visualizzato, exit code) quando il processo muore
    /// senza che sia stato l'utente a fermarlo né parte di un restart.
    /// `logDirectory` iniettabile per i test; in produzione (nil) usa la directory di
    /// default di LogFileWriter. Se `cwd` è impostato (solo nei test) e `logDirectory`
    /// non è specificato esplicitamente, i log di file vanno comunque in una directory
    /// temporanea dedicata invece che nella vera ~/Library/Logs/BackendLauncher.
    init(config: ServiceConfig, cwd: String? = nil, logDirectory: URL? = nil,
         onCrash: ((String, Int32) -> Void)? = nil) {
        self.config = config
        self.cwdOverride = cwd
        self.onCrash = onCrash
        // config.id è namespaced ("Progetto/nome") quando il servizio appartiene a un
        // progetto: "/" non è un carattere valido in un nome di file, e due progetti
        // diversi con lo stesso nome breve altrimenti scriverebbero nello STESSO file di
        // log sovrascrivendosi a vicenda. "-" mantiene il nome leggibile.
        let logFileName = config.id.replacingOccurrences(of: "/", with: "-")
        let resolvedLogDirectory = logDirectory ?? (cwd != nil ? Self.testLogDirectory : nil)
        if let resolvedLogDirectory {
            self.fileWriter = LogFileWriter(serviceName: logFileName, directory: resolvedLogDirectory)
        } else {
            self.fileWriter = LogFileWriter(serviceName: logFileName)
        }
    }

    isolated deinit {
        statsTask?.cancel()
    }

    nonisolated var id: String { config.id }

    var processID: pid_t? { processAlive ? process?.pid : nil }

    var status: ServiceStatus {
        // Il segnale di prontezza dipende dal tipo di probe; confluisce nello stesso
        // ingresso "ready" di derive (che gestisce processAlive/stopRequested/exitCode).
        // Nota: .processAlive usa `processAlive` stesso come segnale — MAI `true` costante,
        // altrimenti prima dello spawn (processAlive=false, ready=true) derive() produrrebbe
        // un fantasma .external (porta "aperta" ma nessun processo nostro).
        let ready: Bool
        switch config.readiness {
        case .tcpPort:
            ready = portOpen
        case .logMarker:
            ready = readyMarkerSeen
        case .processAlive:
            ready = processAlive
        }
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
        fileWriter.appendBanner("avvio \(config.displayName) — \(Date().formatted())")
        epoch += 1
        let myEpoch = epoch
        do {
            let cwd = cwdOverride ?? config.workingDirectory.path
            process = try SpawnedProcess(
                shellCommand: "exec \(config.command)",
                cwd: cwd,
                onChunk: { [weak self] chunk in
                    guard let self, self.epoch == myEpoch else { return }
                    if case .logMarker(let marker) = self.config.readiness,
                       !self.readyMarkerSeen, chunk.localizedCaseInsensitiveContains(marker) {
                        self.readyMarkerSeen = true
                    }
                    self.logs.ingest(chunk)
                    self.fileWriter.append(chunk)
                },
                onExit: { [weak self] code in
                    guard let self, self.epoch == myEpoch else { return }
                    self.handleExit(code)
                }
            )
            processAlive = true
            startedAt = Date()
            startStatsSampling()
        } catch {
            logs.ingest("[launcher] errore avvio: \(error.localizedDescription)\n")
            lastExitCode = -1
        }
    }

    private func startStatsSampling() {
        statsTask?.cancel()
        lastCPUSeconds = nil
        guard let pid = process?.pid else { return }
        statsTask = Task { [weak self] in
            let interval: TimeInterval = 2
            while !Task.isCancelled {
                // syscall bloccanti fuori dal MainActor
                let totals = await Task.detached(priority: .utility) {
                    ProcessStats.groupTotals(pgid: pid)
                }.value
                guard let self, !Task.isCancelled else { return }
                if let previous = self.lastCPUSeconds {
                    self.stats = ProcessStats.sample(previousCPUSeconds: previous,
                                                     currentCPUSeconds: totals.cpuSeconds,
                                                     interval: interval,
                                                     rssBytes: totals.rssBytes)
                }
                self.lastCPUSeconds = totals.cpuSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
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
        let isCrash = !stopRequested && !pendingRestart
        processAlive = false
        process = nil
        startedAt = nil
        lastExitCode = code
        readyMarkerSeen = false
        statsTask?.cancel()
        statsTask = nil
        stats = nil
        lastCPUSeconds = nil
        logs.flushPartial()
        logs.ingest("[launcher] ── processo terminato (exit \(code)) ──\n")
        fileWriter.appendBanner("processo terminato (exit \(code))")
        if isCrash {
            onCrash?(config.displayName, code)
        }
        if pendingRestart {
            pendingRestart = false
            start()
        }
    }
}
