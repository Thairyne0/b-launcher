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
    /// Esito dell'ultimo health check HTTP (readiness `.httpHealth`), aggiornato dal
    /// poller di AppModel come `portOpen`.
    var healthOK = false
    /// Latenza (ms) dell'ultima risposta del health check — diagnosi "su ma lento".
    var healthLatencyMs: Int?
    /// Branch git corrente della working directory (nil = non è un repo), aggiornato
    /// periodicamente dal poller di AppModel — mai calcolato a render time.
    var gitBranch: String?
    /// `true` se `gitBranch` differisce dal branch a maggioranza del progetto (calcolato
    /// da AppModel nello stesso refresh): la card lo evidenzia in arancio.
    var gitBranchMismatch = false

    /// Statistiche CPU/RAM del process group corrente (nil finché non c'è una seconda lettura).
    private(set) var stats: ProcessStats.Sample?
    /// Ultimi ~60s di CPU% (un campione ogni 2s, cap 30) per la sparkline sulla card.
    private(set) var cpuHistory: [Double] = []
    /// Ultimi campioni di latenza del health check (ms), riempiti dal poll di AppModel.
    var latencyHistory: [Double] = []

    /// Append con finestra scorrevole (mantiene gli ULTIMI `cap` valori).
    static func appendCapped(_ value: Double, to values: inout [Double], cap: Int = 30) {
        values.append(value)
        if values.count > cap { values.removeFirst(values.count - cap) }
    }
    private var statsTask: Task<Void, Never>?
    private var lastCPUSeconds: Double?

    // servizi con readiness .logMarker: pronto quando il log annuncia l'avvio
    private(set) var readyMarkerSeen = false

    /// Storico crash per il rilevamento del crash loop (≥3 in 2 min). Stored property:
    /// le mutazioni della struct sono osservate da @Observable, quindi la card si
    /// ridisegna quando cambia. I crash vecchi escono da soli dalla finestra.
    private(set) var crashLoop = CrashLoopDetector()

    var isCrashLooping: Bool { crashLoop.isLooping(at: Date()) }
    var recentCrashCount: Int { crashLoop.recentCrashCount(at: Date()) }

    /// Durata dell'ultimo avvio riuscito (spawn → primo `.running` osservato): alimenta
    /// l'anello di progresso sul pallino durante gli avvii successivi. Solo in memoria.
    private(set) var lastStartupDuration: TimeInterval?
    private var startupMeasured = false

    /// Chiamato dal poll di AppModel quando osserva il servizio `.running`: misura la
    /// durata dell'avvio corrente una volta sola (le osservazioni successive sono no-op).
    func markRunningObserved() {
        guard !startupMeasured, let startedAt else { return }
        startupMeasured = true
        lastStartupDuration = Date().timeIntervalSince(startedAt)
    }

    /// Armato da un crash vero: quando il servizio torna `.running`, AppModel emette la
    /// notifica di recovery ("tornato verde") e lo disarma. Lo stop manuale disarma
    /// senza notifica (l'utente ha ripreso il controllo).
    private(set) var awaitingRecoveryNotice = false

    func clearRecoveryNotice() {
        awaitingRecoveryNotice = false
    }

    /// Storico dei comandi inviati allo stdin (terminale interattivo), per la navigazione
    /// ↑/↓ della barra di input. Solo in memoria, cap 100.
    private(set) var inputHistory: [String] = []

    /// Invia una riga allo stdin del processo (+ `\n`) e la ecoa nel log come «❯ …»
    /// (senza PTY non c'è eco naturale). No-op se il processo non è vivo o la riga è vuota.
    func sendInput(_ line: String) {
        guard processAlive, let process else { return }
        guard !line.isEmpty else { return }
        process.sendInput(line + "\n")
        logs.ingest("❯ \(line)\n")
        inputHistory.append(line)
        if inputHistory.count > 100 { inputHistory.removeFirst(inputHistory.count - 100) }
    }

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

    /// Coda "a scorrimento" degli ultimi caratteri ricevuti, usata solo per readiness
    /// `.logMarker`: un marker può arrivare spezzato a metà tra due chunk della pipe (es.
    /// "SPLIT-MAR" in un `read()` e "KER-XYZ\n" nel successivo). Concatenando la coda al
    /// chunk corrente prima del controllo, un match che attraversa il confine viene comunque
    /// visto. Limitata a `marker.count * 2` per non crescere senza limite.
    private var markerTail = ""

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

    /// URL del file di log su disco per questo servizio (per "Rivela nel Finder" o simili).
    var logFileURL: URL { fileWriter.fileURL }

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
        case .httpHealth:
            ready = healthOK
        }
        return ServiceStatus.derive(processAlive: processAlive, portOpen: ready,
                                    stopRequested: stopRequested, lastExitCode: lastExitCode)
    }

    /// Operatori di shell che rendono un comando "composto": in presenza di uno qualsiasi,
    /// `exec` va OMESSO, perché sostituirebbe l'intera shell con il PRIMO comando e i
    /// successivi (dopo `&&`, `;`, `|`, ...) non verrebbero mai eseguiti. La shell wrapper
    /// resta viva in questi casi, ma il kill del process group la ripulisce comunque insieme
    /// a tutti i suoi figli — nessun orfano.
    private static let shellControlOperators = [";", "&&", "||", "|", ">", "<", "\n", "&"]

    /// Token di assegnazione d'ambiente in testa al comando (es. `PORT=3000 npm start`):
    /// `exec PORT=3000 npm start` non è valido (exec non fa parsing delle assegnazioni come
    /// farebbe la shell), quindi anche in questo caso `exec` va omesso.
    private static let leadingEnvAssignmentPattern = try! NSRegularExpression(
        pattern: #"^\s*[A-Za-z_][A-Za-z0-9_]*="#
    )

    /// Costruisce il comando effettivo passato a `zsh -l -c`:
    /// 1. Sorgente `~/.zshrc` se presente (silenziosamente: alcuni zshrc stampano in output),
    ///    così una shell di login NON interattiva risolve comunque nvm/pyenv/conda come fa il
    ///    terminale dell'utente (zprofile da solo non basta per questi tool, che si agganciano
    ///    tipicamente a .zshrc).
    /// 2. `exec <command>` quando il comando è "semplice" (nessun operatore di shell, nessuna
    ///    assegnazione d'ambiente in testa) — sostituisce la shell wrapper col processo reale,
    ///    utile per una process tree più pulita. Comandi composti restano senza `exec`.
    static func wrappedShellCommand(for command: String) -> String {
        let sourceRC = "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1"
        let canExec = !containsShellControlOperator(command) && !hasLeadingEnvAssignment(command)
        let actual = canExec ? "exec \(command)" : command
        return "\(sourceRC); \(actual)"
    }

    private static func containsShellControlOperator(_ command: String) -> Bool {
        shellControlOperators.contains { command.contains($0) }
    }

    private static func hasLeadingEnvAssignment(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return leadingEnvAssignmentPattern.firstMatch(in: command, range: range) != nil
    }

    /// `commandOverride`: variante one-shot ("Avvia con…") — vale per QUESTO spawn,
    /// il comando di default in config resta invariato.
    func start(commandOverride: String? = nil) {
        guard !processAlive else { return }
        guard status != .external else {
            logs.ingest("[launcher] porta \(config.port.map(String.init) ?? "?") già occupata da un processo esterno — avvio rifiutato\n")
            return
        }
        let command = commandOverride ?? config.command
        stopRequested = false
        lastExitCode = nil
        readyMarkerSeen = false
        startupMeasured = false
        markerTail = ""
        logs.ingest("[launcher] ── avvio \(config.displayName) (\(command)) ──\n")
        fileWriter.appendBanner("avvio \(config.displayName) — \(Date().formatted())")
        epoch += 1
        let myEpoch = epoch
        // File env alternativo: letto ORA (a ogni avvio, così le modifiche si applicano
        // al prossimo start) e iniettato nell'ambiente del figlio. Mai valori nei log.
        var extraEnvironment: [String: String] = [:]
        if let envFilePath = config.envFile {
            if let content = try? String(contentsOf: URL(fileURLWithPath: envFilePath), encoding: .utf8) {
                extraEnvironment = EnvFileWriter.parseEnv(content)
                logs.ingest("[launcher] env alternativo da \(envFilePath) (\(extraEnvironment.count) variabili)\n")
            } else {
                logs.ingest("[launcher] ATTENZIONE: file env \(envFilePath) non leggibile — ignorato\n")
            }
        }
        do {
            let cwd = cwdOverride ?? config.workingDirectory.path
            process = try SpawnedProcess(
                shellCommand: Self.wrappedShellCommand(for: command),
                cwd: cwd,
                extraEnvironment: extraEnvironment,
                onChunk: { [weak self] chunk in
                    guard let self, self.epoch == myEpoch else { return }
                    if case .logMarker(let marker) = self.config.readiness, !self.readyMarkerSeen {
                        // Match sul testo PULITO: con FORCE_COLOR la riga del marker arriva
                        // colorata e gli escape non devono spezzare la frase cercata.
                        let haystack = self.markerTail + ANSIParser.parse(chunk).clean
                        if haystack.localizedCaseInsensitiveContains(marker) {
                            self.readyMarkerSeen = true
                        }
                        self.markerTail = String(haystack.suffix(marker.count * 2))
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
                    let sample = ProcessStats.sample(previousCPUSeconds: previous,
                                                     currentCPUSeconds: totals.cpuSeconds,
                                                     interval: interval,
                                                     rssBytes: totals.rssBytes)
                    self.stats = sample
                    Self.appendCapped(sample.cpuPercent, to: &self.cpuHistory)
                }
                self.lastCPUSeconds = totals.cpuSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        guard processAlive, let process else { return }
        // Stop manuale = l'utente ha ripreso il controllo: il conteggio crash riparte
        // e la notifica di recovery in attesa non ha più senso.
        crashLoop.reset()
        awaitingRecoveryNotice = false
        stopRequested = true
        logs.ingest("[launcher] ── stop richiesto ──\n")
        process.terminate(gracePeriod: AppSettings.killGracePeriodSeconds)
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
        // Un exit 0 non richiesto dall'utente resta comunque uno stato .crashed (vedi
        // ServiceStatus.derive — l'app non lo tratta come .stopped perché il processo NON
        // doveva terminare da solo), ma non è un vero "crash": niente notifica onCrash in
        // questo caso, solo per exit code diverso da zero.
        let isCrash = !stopRequested && !pendingRestart && code != 0
        processAlive = false
        process = nil
        startedAt = nil
        lastExitCode = code
        readyMarkerSeen = false
        markerTail = ""
        statsTask?.cancel()
        statsTask = nil
        stats = nil
        cpuHistory = []
        latencyHistory = []
        lastCPUSeconds = nil
        logs.flushPartial()
        logs.ingest("[launcher] ── processo terminato (exit \(code)) ──\n")
        fileWriter.appendBanner("processo terminato (exit \(code))")
        if isCrash {
            crashLoop.recordCrash(at: Date())
            awaitingRecoveryNotice = true
            onCrash?(config.displayName, code)
        }
        if pendingRestart {
            pendingRestart = false
            start()
        }
    }
}
