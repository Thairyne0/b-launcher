import AppKit
import Foundation
import Observation

/// Radice dello stato dell'app: tutti i controller + spia NATS + azioni globali.
@MainActor
@Observable
final class AppModel {
    private(set) var services: [ServiceController]
    /// Compatibilità storica: stato della spia del PRIMO progetto che ne ha una.
    /// La verità multi-progetto è `infraUp`.
    private(set) var natsUp = false
    /// Stato della spia infrastruttura per progetto (nome progetto → porta raggiungibile).
    /// Solo i progetti con `infraCheck` configurato compaiono qui.
    private(set) var infraUp: [String: Bool] = [:]
    /// Tutte le spie configurate, in ordine di progetto nello store.
    private(set) var infraChecks: [(projectName: String, check: StoredInfraCheck)] = []
    /// Il check che ha fatto scattare l'ultimo warning (per titolo/messaggio dell'alert).
    private(set) var warningInfraCheck: StoredInfraCheck?
    var showNATSWarning = false
    var stopAllRequested = false
    var expandedServices: Set<String> = []
    /// Incrementato a ogni `revealService`: la view lo osserva per riportare la pagina
    /// attiva su "Backend" quando l'utente tocca una notifica di crash.
    private(set) var revealRequestCount = 0
    /// Id (namespaced) dell'ultimo servizio rivelato da `revealService`: la view lo usa per
    /// navigare direttamente sul pannello del servizio invece di ricadere sulla griglia.
    private(set) var lastRevealedServiceID: String?

    /// `nil` quando l'AppModel è creato con l'init legacy (`configs:`), usato dai test esistenti.
    let store: ServiceStore?
    /// Infra check (es. NATS) del primo progetto che ne ha uno configurato.
    /// Limite noto: con più progetti l'app ha un solo indicatore NATS globale — non c'è
    /// ancora UI per un infra check per-progetto (fuori scope Phase D).
    private(set) var infraCheck: StoredInfraCheck?
    /// Profili di avvio "piatti": nell'init legacy sono `ServiceConfig.legacyProfiles`;
    /// nell'init store-driven sono i profili del PRIMO progetto (comportamento storico
    /// preservato per compatibilità con `start(profile:)` e i test esistenti). Per la UI
    /// multi-progetto usare `projectProfiles`, che copre tutti i progetti.
    private(set) var profiles: [LaunchProfile]
    /// Profili raggruppati per progetto, in ordine — usati dal menu "Profili" quando
    /// ci sono più progetti (submenu per progetto) e da `start(profile:inProject:)`.
    private(set) var projectProfiles: [(projectName: String, profiles: [LaunchProfile])] = []
    /// Id (namespaced) dei servizi la cui configurazione su disco è cambiata mentre il
    /// relativo processo era in esecuzione: `reloadFromStore()` non sostituisce un
    /// controller vivo (fermerebbe silenziosamente il processo dell'utente), quindi la
    /// nuova config resta "in sospeso" finché il servizio non viene fermato — al successivo
    /// `reloadFromStore()` la sostituzione avviene normalmente. La UI può mostrare un badge
    /// "riavvia per applicare le modifiche" leggendo questo set.
    private(set) var pendingConfigChanges: Set<String> = []
    /// Id dei progetti il cui template `.blauncher.json` tracciato (`StoredProject.templateSync`)
    /// è cambiato sul disco rispetto all'ultimo import/sync — la UI mostra un banner "Sincronizza"
    /// per questi. Ricalcolato a ogni `reloadFromStore()` e periodicamente dal poll loop (il
    /// file può cambiare senza che l'utente tocchi lo store, es. `git pull` da terminale).
    private(set) var templateSyncAvailable: Set<String> = []

    private var pollTask: Task<Void, Never>?
    /// Avvii orchestrati (ondate `startAfter`) in corso, per chiave di contesto (nome
    /// progetto, "tutti", "profilo:X"): uno stop dello stesso contesto li cancella.
    private var orchestrations: [String: Task<Void, Never>] = [:]
    private let crashNotificationsEnabled: Bool
    /// Contatore di cicli di poll: il controllo di sync dei template è più costoso (lettura file)
    /// di un semplice check porta, quindi gira ogni ~10 tick invece che a ogni tick — con
    /// `AppSettings.pollIntervalSeconds` di default (~2s) equivale a circa ogni 20s.
    private var pollTickCount = 0

    /// Init store-driven: costruisce i controller per TUTTI i progetti dello store (id
    /// namespaced "Progetto/nome"), non solo il primo — supporto multi-progetto reale.
    init(store: ServiceStore,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        self.store = store
        self.crashNotificationsEnabled = crashNotificationsEnabled
        self.infraCheck = store.projects.first { $0.infraCheck != nil }?.infraCheck
        self.infraChecks = store.projects.compactMap { project in
            project.infraCheck.map { (projectName: project.name, check: $0) }
        }
        let (flatProfiles, grouped) = Self.buildProfiles(from: store.projects)
        self.profiles = flatProfiles
        self.projectProfiles = grouped
        let configs = store.projects.flatMap(store.serviceConfigs(for:))
        services = configs.map { Self.makeController(config: $0, cwd: nil, crashNotificationsEnabled: crashNotificationsEnabled) }
        refreshTemplateSyncAvailability()
        if pollingEnabled { startPolling() }
    }

    /// Init legacy: `configs`, `cwd`, `pollingEnabled` e `crashNotificationsEnabled` iniettabili
    /// per i test. `store` è `nil` e `infraCheck` resta NATS 4222 (comportamento storico).
    init(configs: [ServiceConfig] = ServiceConfig.legacyAll,
         cwd: String? = nil,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        self.store = nil
        self.crashNotificationsEnabled = crashNotificationsEnabled
        self.infraCheck = StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort)
        self.infraChecks = [(projectName: "", check: StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort))]
        self.profiles = ServiceConfig.legacyProfiles
        self.projectProfiles = [(projectName: "", profiles: ServiceConfig.legacyProfiles)]
        services = configs.map { Self.makeController(config: $0, cwd: cwd, crashNotificationsEnabled: crashNotificationsEnabled) }
        if pollingEnabled { startPolling() }
    }

    private static func buildProfiles(from projects: [StoredProject]) -> (flat: [LaunchProfile], grouped: [(projectName: String, profiles: [LaunchProfile])]) {
        let grouped = projects.map { project in
            (projectName: project.name, profiles: project.profiles.map {
                LaunchProfile(name: $0.name, serviceNames: $0.serviceNames)
            })
        }
        return (grouped.first?.profiles ?? [], grouped)
    }

    private static func makeController(config: ServiceConfig, cwd: String?, crashNotificationsEnabled: Bool) -> ServiceController {
        let onCrash: ((String, Int32) -> Void)? = crashNotificationsEnabled
            ? { displayName, code in
                CrashNotifier.notifyCrash(service: displayName, serviceID: config.id, exitCode: code)
            }
            : nil
        return ServiceController(config: config, cwd: cwd, onCrash: onCrash)
    }

    /// Ricostruisce `services` dallo stato corrente dello store dopo una mutazione
    /// (add/edit/delete di progetti o servizi dal wizard). Regole:
    /// - un controller esistente la cui config è INVARIATA viene mantenuto (stessa istanza:
    ///   niente terminale/stato perso per servizi non toccati dalla modifica);
    /// - se la config è cambiata e il processo non è vivo, il controller viene sostituito;
    /// - se la config è cambiata ma il processo È vivo, il controller vecchio resta (non
    ///   vogliamo fermare un processo dell'utente sotto silenzio) e il suo id entra in
    ///   `pendingConfigChanges` finché non viene fermato e ricaricato di nuovo;
    /// - un id non più presente nello store viene fermato (se vivo) e rimosso dall'array;
    /// - un id nuovo ottiene un controller fresco.
    func reloadFromStore() {
        guard let store else { return }
        self.infraCheck = store.projects.first { $0.infraCheck != nil }?.infraCheck
        self.infraChecks = store.projects.compactMap { project in
            project.infraCheck.map { (projectName: project.name, check: $0) }
        }
        self.infraUp = self.infraUp.filter { key, _ in
            self.infraChecks.contains { $0.projectName == key }
        }
        let (flatProfiles, grouped) = Self.buildProfiles(from: store.projects)
        self.profiles = flatProfiles
        self.projectProfiles = grouped

        let targetConfigs = store.projects.flatMap(store.serviceConfigs(for:))
        let targetByID = Dictionary(uniqueKeysWithValues: targetConfigs.map { ($0.id, $0) })
        let existingByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })

        // Servizi rimossi dallo store: ferma (se vivo) e scarta il riferimento. Il processo
        // sottostante resta vivo fino al reap (SpawnedProcess si auto-mantiene nel registry),
        // ma non ci serve più tenerne il controller.
        for controller in services where targetByID[controller.id] == nil {
            if controller.processAlive { controller.stop() }
        }

        var newServices: [ServiceController] = []
        newServices.reserveCapacity(targetConfigs.count)
        for config in targetConfigs {
            if let existing = existingByID[config.id] {
                if existing.config == config {
                    newServices.append(existing)
                    pendingConfigChanges.remove(config.id)
                } else if existing.processAlive {
                    // Config cambiata ma il servizio è in esecuzione: mantieni il controller
                    // vivo, la nuova config si applica al prossimo reload dopo lo stop.
                    newServices.append(existing)
                    pendingConfigChanges.insert(config.id)
                } else {
                    newServices.append(Self.makeController(config: config, cwd: nil, crashNotificationsEnabled: crashNotificationsEnabled))
                    pendingConfigChanges.remove(config.id)
                }
            } else {
                newServices.append(Self.makeController(config: config, cwd: nil, crashNotificationsEnabled: crashNotificationsEnabled))
            }
        }
        services = newServices

        let liveIDs = Set(services.map(\.id))
        expandedServices = expandedServices.intersection(liveIDs)
        pendingConfigChanges = pendingConfigChanges.intersection(liveIDs)
        updateDockBadge()
        refreshTemplateSyncAvailability()
    }

    /// Ricalcola `templateSyncAvailable` interrogando `ServiceStore.checkTemplateSync` per ogni
    /// progetto tracciato. Costo contenuto: un progetto non tracciato (`templateSync == nil`,
    /// il caso comune) è scartato senza toccare il filesystem; solo i progetti importati da un
    /// template dentro la propria root leggono un piccolo file JSON.
    private func refreshTemplateSyncAvailability() {
        guard let store else { return }
        var changed: Set<String> = []
        for project in store.projects where project.templateSync != nil {
            if case .changed = store.checkTemplateSync(projectID: project.id) {
                changed.insert(project.id)
            }
        }
        templateSyncAvailable = changed
    }

    /// Porta l'attenzione su un servizio: espande il suo terminale e filtra sugli errori.
    /// Usato dal deep-link della notifica di crash. `id` è l'id namespaced (config.id).
    /// Fallback: notifiche create prima del namespacing portano il solo nome breve (config.name)
    /// nello userInfo — se non c'è match esatto sull'id, prova un match univoco sul nome.
    func revealService(named id: String) {
        let service: ServiceController?
        if let exact = services.first(where: { $0.id == id }) {
            service = exact
        } else {
            let byName = services.filter { $0.config.name == id }
            service = byName.count == 1 ? byName[0] : nil
        }
        guard let service else { return }
        expandedServices.insert(service.id)
        service.logs.levelFilter = .errors
        lastRevealedServiceID = service.id
        revealRequestCount += 1
    }

    /// Riga di errore di un servizio, per il pannello errori globale.
    struct GlobalErrorEntry: Identifiable {
        let serviceID: String
        let serviceName: String
        let line: LogLine
        var id: String { "\(serviceID)#\(line.id)" }
    }

    /// Errori di TUTTI i servizi, dal più recente, cap a 500 (il pannello è per "cosa
    /// sta succedendo adesso", non un archivio — i log completi restano nei terminali).
    /// Derivato on-demand dai LogStore esistenti: nessun secondo buffer da mantenere.
    var globalErrors: [GlobalErrorEntry] {
        var entries: [GlobalErrorEntry] = []
        for service in services {
            for line in service.logs.lines where line.level == .error {
                entries.append(GlobalErrorEntry(serviceID: service.id,
                                                serviceName: service.config.displayName,
                                                line: line))
            }
        }
        entries.sort { $0.line.receivedAt > $1.line.receivedAt }
        return Array(entries.prefix(500))
    }

    /// Gruppo di errori IDENTICI (stesso servizio + stesso testo) per il pannello errori:
    /// una riga sola con conteggio, timestamp dell'occorrenza più recente.
    struct GlobalErrorGroup: Identifiable {
        let serviceID: String
        let serviceName: String
        let text: String
        let count: Int
        let lastReceivedAt: Date
        var id: String { "\(serviceID)#\(text.hashValue)" }
    }

    /// Chiave di raggruppamento di una riga di errore: dal marker di livello in poi.
    /// I log reali hanno pid/timestamp PRIMA del marker ("[Nest] 123 - 10:00:01 ERROR …"):
    /// l'exact-match non raggrupperebbe mai due occorrenze dello stesso errore. Dal marker
    /// in avanti restano contesto e messaggio, che sono ciò che rende "uguale" un errore.
    static func errorGroupingKey(for text: String) -> String {
        for marker in ["ERROR", "FATAL"] {
            if let range = text.range(of: marker) {
                return String(text[range.lowerBound...])
            }
        }
        return text
    }

    /// `globalErrors` raggruppati: l'errore ripetuto (es. ECONNREFUSED in loop) diventa
    /// una riga con "×N" invece di N righe che seppelliscono il resto. Il testo mostrato
    /// è quello dell'occorrenza più recente.
    var globalErrorGroups: [GlobalErrorGroup] {
        var order: [String] = []
        var byKey: [String: (entry: GlobalErrorEntry, count: Int, last: Date)] = [:]
        for entry in globalErrors {
            let key = "\(entry.serviceID)#\(Self.errorGroupingKey(for: entry.line.text))"
            if var existing = byKey[key] {
                existing.count += 1
                if entry.line.receivedAt >= existing.last {
                    existing.last = entry.line.receivedAt
                    existing.entry = entry
                }
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = (entry, 1, entry.line.receivedAt)
            }
        }
        return order.compactMap { key -> GlobalErrorGroup? in
            guard let value = byKey[key] else { return nil }
            return GlobalErrorGroup(serviceID: value.entry.serviceID,
                                    serviceName: value.entry.serviceName,
                                    text: value.entry.line.text,
                                    count: value.count,
                                    lastReceivedAt: value.last)
        }
        .sorted { $0.lastReceivedAt > $1.lastReceivedAt }
    }

    /// Servizi raggruppati per progetto, preservando l'ordine di prima apparizione del
    /// `projectName` in `services` (che rispecchia l'ordine dei progetti nello store).
    /// Usato dalla menu bar per offrire avvia/ferma per singolo progetto.
    var servicesByProject: [(projectName: String, services: [ServiceController])] {
        var order: [String] = []
        var buckets: [String: [ServiceController]] = [:]
        for service in services {
            let key = service.config.projectName
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(service)
        }
        return order.map { (projectName: $0, services: buckets[$0] ?? []) }
    }

    var anyRunning: Bool { services.contains { $0.processAlive } }
    var allExpanded: Bool { expandedServices.count == services.count }

    func toggleAllTerminals() {
        expandedServices = allExpanded ? [] : Set(services.map(\.id))
    }

    func toggleTerminal(_ id: String) {
        if expandedServices.contains(id) { expandedServices.remove(id) } else { expandedServices.insert(id) }
    }

    func startAll() {
        // Avvisa (ma procedi, come da spec storica) se QUALSIASI spia configurata è giù.
        if let down = firstDownInfra {
            warningInfraCheck = down
            showNATSWarning = true
        }
        // Ogni progetto è orchestrato per conto suo (le dipendenze non attraversano i progetti).
        for group in servicesByProject {
            startRespectingDependencies(group.services.filter { !$0.processAlive },
                                        orchestrationKey: group.projectName)
        }
    }

    func stopAll() {
        for task in orchestrations.values { task.cancel() }
        orchestrations.removeAll()
        for service in services { service.stop() }
    }

    // MARK: - Avvio orchestrato (startAfter)

    /// Avvia `controllers` rispettando `startAfter`: ondate topologiche, ogni ondata parte
    /// quando la precedente è pronta (status running) o dopo `waveTimeout` a ondata —
    /// scaduto il timeout si procede comunque (meglio un avvio "anticipato" di un deadlock).
    /// Nessuna dipendenza nel set → percorso storico (start piatto immediato).
    /// Dipendenze verso servizi FUORI dal set: soddisfatte se il servizio è già running,
    /// altrimenti ignorate (non possiamo attendere chi non stiamo avviando).
    private func startRespectingDependencies(_ controllers: [ServiceController],
                                             orchestrationKey: String,
                                             waveTimeout: TimeInterval = 90) {
        guard controllers.contains(where: { !$0.config.startAfter.isEmpty }) else {
            controllers.forEach { $0.start() }
            return
        }
        let setNames = Set(controllers.map(\.config.name))
        let projectName = controllers.first?.config.projectName ?? ""
        let alreadyRunning = Set(services
            .filter { $0.config.projectName == projectName && $0.status == .running }
            .map(\.config.name))
        let entries = controllers.map { controller in
            (name: controller.config.name,
             startAfter: controller.config.startAfter.filter {
                 setNames.contains($0) && !alreadyRunning.contains($0)
             })
        }
        guard let waves = StartOrchestrator.waves(services: entries) else {
            for controller in controllers {
                controller.logs.ingest("[launcher] dipendenze circolari nel progetto — avvio senza ordine\n")
                controller.start()
            }
            return
        }
        let byName = Dictionary(uniqueKeysWithValues: controllers.map { ($0.config.name, $0) })
        orchestrations[orchestrationKey]?.cancel()
        orchestrations[orchestrationKey] = Task { [weak self] in
            for (index, wave) in waves.enumerated() {
                guard !Task.isCancelled else { return }
                let waveControllers = wave.compactMap { byName[$0] }
                for controller in waveControllers where !controller.processAlive {
                    if index > 0 {
                        controller.logs.ingest("[launcher] avvio in ondata \(index + 1) (dopo: \(controller.config.startAfter.joined(separator: ", ")))\n")
                    }
                    controller.start()
                }
                guard index < waves.count - 1 else { break }  // ultima ondata: niente attesa
                let deadline = Date().addingTimeInterval(waveTimeout)
                while Date() < deadline, !Task.isCancelled {
                    // In attesa solo dei vivi non ancora pronti: un servizio morto nel
                    // frattempo (crash) non deve bloccare le ondate successive.
                    let pending = waveControllers.contains {
                        $0.processAlive && $0.status != .running
                    }
                    if !pending { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            _ = self
        }
    }

    /// Avvia un profilo facendo match sul nome breve tra TUTTI i servizi (comportamento
    /// storico, corretto quando c'è un solo progetto). Con più progetti che condividono
    /// nomi di servizio, preferire `start(profile:inProject:)`.
    func start(profile: LaunchProfile) {
        if let down = firstDownInfra {
            warningInfraCheck = down
            showNATSWarning = true
        }
        let targets = services.filter {
            profile.serviceNames.contains($0.config.name) && !$0.processAlive
        }
        startRespectingDependencies(targets, orchestrationKey: "profilo:\(profile.name)")
    }

    /// Avvia un profilo appartenente a un progetto specifico: il match è sul nome breve
    /// MA ristretto ai servizi di quel progetto (namespaced id "progetto/nome"), così due
    /// progetti con servizi omonimi non si confondono.
    func start(profile: LaunchProfile, inProject projectName: String) {
        warnIfInfraDown(forProject: projectName)
        let targets = services.filter {
            $0.config.projectName == projectName
                && profile.serviceNames.contains($0.config.name)
                && !$0.processAlive
        }
        startRespectingDependencies(targets, orchestrationKey: "profilo:\(projectName)/\(profile.name)")
    }

    /// Avvia tutti i servizi non ancora vivi di UN progetto specifico (match su
    /// `config.projectName`, non sul nome breve del servizio). Stessa guardia NATS di
    /// `startAll()`: avvisa (se l'infra check non è su) ma procede comunque.
    func startProject(named projectName: String) {
        warnIfInfraDown(forProject: projectName)
        let targets = services.filter {
            $0.config.projectName == projectName && !$0.processAlive
        }
        startRespectingDependencies(targets, orchestrationKey: projectName)
    }

    /// Ferma tutti i servizi vivi di UN progetto specifico (match su `config.projectName`).
    func stopProject(named projectName: String) {
        orchestrations[projectName]?.cancel()
        orchestrations[projectName] = nil
        for service in services where service.config.projectName == projectName {
            service.stop()
        }
    }

    /// Riavvia ciò che gira in UN progetto specifico: i servizi vivi (`processAlive`)
    /// vengono riavviati con `restart()`; i servizi non vivi (fermi o crashati) restano
    /// INVARIATI — "riavvia" non significa "avvia tutto", è un refresh di ciò che è già
    /// in esecuzione, non un semplice alias di `startProject`.
    func restartProject(named projectName: String) {
        for service in services
        where service.config.projectName == projectName && service.processAlive {
            service.restart()
        }
    }

    /// Stessa semantica di `restartProject`, ma su TUTTI i progetti: riavvia solo i
    /// servizi vivi, lascia invariati quelli fermi/crashati.
    func restartAll() {
        for service in services where service.processAlive {
            service.restart()
        }
    }

    /// Svuota il terminale (log in-memory) di tutti i servizi di UN progetto specifico.
    /// Non tocca il file di log su disco né lo stato del processo.
    func clearProjectTerminals(named projectName: String) {
        for service in services where service.config.projectName == projectName {
            service.logs.clear()
        }
    }

    /// Aggiorna il badge del dock con il numero di servizi in stato `.crashed`.
    /// Guardia: `Bundle.main.bundleIdentifier` è `nil` da `swift test`/`swift run` (binario
    /// nudo) — stesso pattern di `CrashNotifier.isAvailable`, per non toccare `NSApp` nei test.
    private func updateDockBadge() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let crashedCount = services.filter {
            if case .crashed = $0.status { return true }
            return false
        }.count
        NSApp.dockTile.badgeLabel = crashedCount > 0 ? "\(crashedCount)" : nil
    }

    /// Stop di tutto con attesa (grace di killpg configurabile + margine). Per il quit.
    /// Il minimo storico di 6.5s resta come pavimento anche se la grace configurata è più bassa.
    func shutdownForQuit() async {
        stopAll()
        let timeout = max(6.5, AppSettings.killGracePeriodSeconds + 1.5)
        let deadline = Date().addingTimeInterval(timeout)
        while anyRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Notifica "tornato verde" per i servizi crashati che sono tornati `.running`.
    /// Chiamato dal poll a ogni tick; ritorna gli id notificati (testabilità).
    @discardableResult
    func emitRecoveryNotices() -> [String] {
        var notified: [String] = []
        for service in services where service.awaitingRecoveryNotice && service.status == .running {
            service.clearRecoveryNotice()
            notified.append(service.id)
            if crashNotificationsEnabled {
                CrashNotifier.notifyRecovery(service: service.config.displayName,
                                             serviceID: service.id)
            }
        }
        return notified
    }

    /// Aggiorna `infraUp`/`natsUp` da un esito di probe porte. Estratto dal poll per
    /// poterlo pilotare nei test (`refreshInfraStatus`).
    private func applyInfraResults(_ results: [UInt16: Bool]) {
        var up: [String: Bool] = [:]
        for entry in infraChecks {
            up[entry.projectName] = results[entry.check.port] ?? false
        }
        infraUp = up
        natsUp = infraChecks.first.flatMap { up[$0.projectName] } ?? false
    }

    /// Probe immediato di tutte le spie infra configurate (fuori dal ciclo di poll).
    func refreshInfraStatus() async {
        let results = await Self.checkPorts(infraChecks.map(\.check.port))
        applyInfraResults(results)
    }

    /// Primo check configurato che NON risulta raggiungibile (stato sconosciuto = giù,
    /// come lo storico default `natsUp == false` prima del primo poll).
    private var firstDownInfra: StoredInfraCheck? {
        infraChecks.first { infraUp[$0.projectName] != true }?.check
    }

    /// Warning per l'avvio di un progetto specifico: usa la SUA spia, non la globale.
    private func warnIfInfraDown(forProject projectName: String) {
        guard let entry = infraChecks.first(where: { $0.projectName == projectName }),
              infraUp[entry.projectName] != true else { return }
        warningInfraCheck = entry.check
        showNATSWarning = true
    }

    /// Aggiorna `gitBranch`/`gitBranchMismatch` di ogni controller: spawn di `git` fuori
    /// dal MainActor, un giro ogni ~10 tick di poll (≈20s) + uno all'avvio del polling.
    /// Il "mismatch" è rispetto al branch a maggioranza assoluta del progetto: evidenzia
    /// il servizio rimasto su un branch diverso (es. worktree dimenticato).
    func refreshGitBranches() async {
        let targets = services.map { (id: $0.id, directory: $0.config.workingDirectory) }
        let branches = await Task.detached(priority: .utility) {
            var out: [String: String?] = [:]
            for target in targets { out[target.id] = GitBranch.current(in: target.directory) }
            return out
        }.value
        for service in services {
            service.gitBranch = branches[service.id] ?? nil
        }
        for group in servicesByProject {
            let known = group.services.compactMap(\.gitBranch)
            let majority = GitBranch.majority(of: known)
            for service in group.services {
                service.gitBranchMismatch = majority != nil
                    && service.gitBranch != nil
                    && service.gitBranch != majority
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            var firstTick = true
            while !Task.isCancelled {
                guard let self else { return }
                let infraPorts = self.infraChecks.map(\.check.port)
                let ports = infraPorts + self.services.compactMap(\.config.port)
                let results = await Self.checkPorts(ports)
                self.applyInfraResults(results)
                for service in self.services {
                    if let p = service.config.port {
                        service.portOpen = results[p] ?? false
                    }
                }
                // Health check HTTP per i servizi con readiness .httpHealth.
                let healthTargets: [(id: String, endpoint: HealthEndpoint)] = self.services.compactMap {
                    guard case .httpHealth(let port, let path) = $0.config.readiness else { return nil }
                    return ($0.id, HealthEndpoint(port: port, path: path))
                }
                if !healthTargets.isEmpty {
                    let healthResults = await Self.checkHealthEndpoints(healthTargets.map(\.endpoint))
                    for target in healthTargets {
                        guard let service = self.services.first(where: { $0.id == target.id }) else { continue }
                        let result = healthResults[target.endpoint]
                        service.healthOK = result?.ok ?? false
                        service.healthLatencyMs = result?.latencyMs
                        if let ms = result?.latencyMs {
                            ServiceController.appendCapped(Double(ms), to: &service.latencyHistory)
                        }
                    }
                }
                // Modifiche di config in sospeso: quando il servizio interessato si è
                // fermato, ricarica dallo store per applicarle (e togliere il badge).
                if self.pendingConfigChanges.contains(where: { id in
                    self.services.first { $0.id == id }?.processAlive != true
                }) {
                    self.reloadFromStore()
                }
                self.emitRecoveryNotices()
                for service in self.services where service.processAlive && service.status == .running {
                    service.markRunningObserved()
                }
                self.updateDockBadge()
                // Controllo sync template: costa una lettura file per progetto tracciato, quindi
                // gira ogni 10 tick (~20s coi valori di default) invece che a ogni giro di poll.
                self.pollTickCount += 1
                if firstTick || self.pollTickCount >= 10 {
                    firstTick = false
                    self.pollTickCount = 0
                    self.refreshTemplateSyncAvailability()
                    await self.refreshGitBranches()
                }
                let pollSeconds = AppSettings.pollIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
        }
    }

    /// Probe di più porte fuori dal MainActor.
    /// Nota: loop sequenziale intenzionale — su loopback una porta chiusa risponde
    /// ECONNREFUSED in microsecondi, il costo per ciclo è trascurabile.
    static func checkPorts(_ ports: [UInt16]) async -> [UInt16: Bool] {
        let unique = Array(Set(ports))
        return await Task.detached(priority: .utility) {
            var out: [UInt16: Bool] = [:]
            for port in unique { out[port] = PortCheck.isOpen(port) }
            return out
        }.value
    }

    // MARK: - Health check HTTP (readiness .httpHealth)

    /// Endpoint di health di un servizio: porta + path su 127.0.0.1.
    struct HealthEndpoint: Hashable, Sendable {
        let port: UInt16
        let path: String
    }

    /// Sessione dedicata ai probe: timeout stretti (il poll gira ogni ~2s, un backend sano
    /// su loopback risponde in millisecondi), niente cache, niente redirect (vedi delegate).
    private static let healthSession = URLSession(
        configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 1.5
            configuration.timeoutIntervalForResource = 1.5
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return configuration
        }(),
        delegate: HealthProbeNoRedirectDelegate(),
        delegateQueue: nil
    )

    /// Esito di un probe: pronto (2xx) + latenza della risposta HTTP, se ce n'è stata una
    /// (anche non-2xx). Connessione fallita → `latencyMs` nil.
    struct HealthProbeResult: Equatable, Sendable {
        let ok: Bool
        let latencyMs: Int?
    }

    /// GET concorrente su ogni endpoint; 2xx = pronto. Un redirect (es. verso una pagina di
    /// login) NON è "pronto": conta lo status della prima risposta.
    static func checkHealthEndpoints(_ endpoints: [HealthEndpoint]) async -> [HealthEndpoint: HealthProbeResult] {
        let unique = Array(Set(endpoints))
        var results: [HealthEndpoint: HealthProbeResult] = [:]
        await withTaskGroup(of: (HealthEndpoint, HealthProbeResult).self) { group in
            for endpoint in unique {
                group.addTask { (endpoint, await Self.probeHealth(endpoint)) }
            }
            for await (endpoint, result) in group {
                results[endpoint] = result
            }
        }
        return results
    }

    private static func probeHealth(_ endpoint: HealthEndpoint) async -> HealthProbeResult {
        let path = endpoint.path.hasPrefix("/") ? endpoint.path : "/" + endpoint.path
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)\(path)") else {
            return HealthProbeResult(ok: false, latencyMs: nil)
        }
        let clock = ContinuousClock()
        let start = clock.now
        guard let (_, response) = try? await healthSession.data(from: url),
              let http = response as? HTTPURLResponse else {
            return HealthProbeResult(ok: false, latencyMs: nil)
        }
        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return HealthProbeResult(ok: (200..<300).contains(http.statusCode), latencyMs: ms)
    }
}

/// Blocca i redirect dei probe di health: `completionHandler(nil)` restituisce la risposta
/// 3xx originale invece di seguirla. Top-level (non nested in AppModel) per non ereditare
/// l'isolamento MainActor — URLSession chiama il delegate sulla propria coda.
private final class HealthProbeNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
