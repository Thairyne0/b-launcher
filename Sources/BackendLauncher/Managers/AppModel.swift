import Foundation
import Observation

/// Radice dello stato dell'app: tutti i controller + spia NATS + azioni globali.
@MainActor
@Observable
final class AppModel {
    private(set) var services: [ServiceController]
    private(set) var natsUp = false
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

    private var pollTask: Task<Void, Never>?
    private let crashNotificationsEnabled: Bool

    /// Init store-driven: costruisce i controller per TUTTI i progetti dello store (id
    /// namespaced "Progetto/nome"), non solo il primo — supporto multi-progetto reale.
    init(store: ServiceStore,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        self.store = store
        self.crashNotificationsEnabled = crashNotificationsEnabled
        self.infraCheck = store.projects.first { $0.infraCheck != nil }?.infraCheck
        let (flatProfiles, grouped) = Self.buildProfiles(from: store.projects)
        self.profiles = flatProfiles
        self.projectProfiles = grouped
        let configs = store.projects.flatMap(store.serviceConfigs(for:))
        services = configs.map { Self.makeController(config: $0, cwd: nil, crashNotificationsEnabled: crashNotificationsEnabled) }
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

    var anyRunning: Bool { services.contains { $0.processAlive } }
    var allExpanded: Bool { expandedServices.count == services.count }

    func toggleAllTerminals() {
        expandedServices = allExpanded ? [] : Set(services.map(\.id))
    }

    func toggleTerminal(_ id: String) {
        if expandedServices.contains(id) { expandedServices.remove(id) } else { expandedServices.insert(id) }
    }

    func startAll() {
        if !natsUp { showNATSWarning = true }  // avvisa ma procedi (spec)
        for service in services where !service.processAlive {
            service.start()
        }
    }

    func stopAll() {
        for service in services { service.stop() }
    }

    /// Avvia un profilo facendo match sul nome breve tra TUTTI i servizi (comportamento
    /// storico, corretto quando c'è un solo progetto). Con più progetti che condividono
    /// nomi di servizio, preferire `start(profile:inProject:)`.
    func start(profile: LaunchProfile) {
        if !natsUp { showNATSWarning = true }
        for service in services
        where profile.serviceNames.contains(service.config.name) && !service.processAlive {
            service.start()
        }
    }

    /// Avvia un profilo appartenente a un progetto specifico: il match è sul nome breve
    /// MA ristretto ai servizi di quel progetto (namespaced id "progetto/nome"), così due
    /// progetti con servizi omonimi non si confondono.
    func start(profile: LaunchProfile, inProject projectName: String) {
        if !natsUp { showNATSWarning = true }
        for service in services
        where service.config.projectName == projectName
            && profile.serviceNames.contains(service.config.name)
            && !service.processAlive {
            service.start()
        }
    }

    /// Avvia tutti i servizi non ancora vivi di UN progetto specifico (match su
    /// `config.projectName`, non sul nome breve del servizio). Stessa guardia NATS di
    /// `startAll()`: avvisa (se l'infra check non è su) ma procede comunque.
    func startProject(named projectName: String) {
        if !natsUp && infraCheck != nil { showNATSWarning = true }
        for service in services
        where service.config.projectName == projectName && !service.processAlive {
            service.start()
        }
    }

    /// Ferma tutti i servizi vivi di UN progetto specifico (match su `config.projectName`).
    func stopProject(named projectName: String) {
        for service in services where service.config.projectName == projectName {
            service.stop()
        }
    }

    /// Stop di tutto con attesa (max ~6s: grace 5s di killpg + margine). Per il quit.
    func shutdownForQuit() async {
        stopAll()
        let deadline = Date().addingTimeInterval(6.5)
        while anyRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let infraPort = self.infraCheck?.port
                let ports = (infraPort.map { [$0] } ?? []) + self.services.compactMap(\.config.port)
                let results = await Self.checkPorts(ports)
                self.natsUp = infraPort.flatMap { results[$0] } ?? false
                for service in self.services {
                    if let p = service.config.port {
                        service.portOpen = results[p] ?? false
                    }
                }
                // Modifiche di config in sospeso: quando il servizio interessato si è
                // fermato, ricarica dallo store per applicarle (e togliere il badge).
                if self.pendingConfigChanges.contains(where: { id in
                    self.services.first { $0.id == id }?.processAlive != true
                }) {
                    self.reloadFromStore()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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
}
