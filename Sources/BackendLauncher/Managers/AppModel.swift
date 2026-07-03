import Foundation
import Observation

/// Radice dello stato dell'app: tutti i controller + spia NATS + azioni globali.
@MainActor
@Observable
final class AppModel {
    let services: [ServiceController]
    private(set) var natsUp = false
    var showNATSWarning = false
    var stopAllRequested = false
    var expandedServices: Set<String> = []
    /// Incrementato a ogni `revealService`: la view lo osserva per riportare la pagina
    /// attiva su "Backend" quando l'utente tocca una notifica di crash.
    private(set) var revealRequestCount = 0

    /// `nil` quando l'AppModel è creato con l'init legacy (`configs:`), usato dai test esistenti.
    let store: ServiceStore?
    /// Infra check (es. NATS) del progetto attivo. Nell'init legacy default a NATS 4222
    /// per preservare il comportamento storico del poller.
    private(set) var infraCheck: StoredInfraCheck?
    /// Profili di avvio del progetto attivo (store) o fallback legacy (init di test).
    let profiles: [LaunchProfile]

    private var pollTask: Task<Void, Never>?

    /// Init store-driven: legge il progetto attivo dallo store e ne deriva servizi/profili/infra check.
    init(store: ServiceStore,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        self.store = store
        let project = store.activeProject
        let configs = project.map(store.serviceConfigs(for:)) ?? []
        self.infraCheck = project?.infraCheck ?? StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort)
        self.profiles = (project?.profiles ?? []).map {
            LaunchProfile(name: $0.name, serviceNames: $0.serviceNames)
        }
        services = configs.map { config in
            let onCrash: ((String, Int32) -> Void)? = crashNotificationsEnabled
                ? { displayName, code in
                    CrashNotifier.notifyCrash(service: displayName, serviceID: config.name, exitCode: code)
                }
                : nil
            return ServiceController(config: config, cwd: nil, onCrash: onCrash)
        }
        if pollingEnabled { startPolling() }
    }

    /// Init legacy: `configs`, `cwd`, `pollingEnabled` e `crashNotificationsEnabled` iniettabili
    /// per i test. `store` è `nil` e `infraCheck` resta NATS 4222 (comportamento storico).
    init(configs: [ServiceConfig] = ServiceConfig.legacyAll,
         cwd: String? = nil,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        self.store = nil
        self.infraCheck = StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort)
        self.profiles = ServiceConfig.legacyProfiles
        services = configs.map { config in
            // onCrash riceve (nome visualizzato, exit code) da ServiceController; il nome
            // breve (config.name) per lo userInfo/deep-link è catturato qui dalla config.
            let onCrash: ((String, Int32) -> Void)? = crashNotificationsEnabled
                ? { displayName, code in
                    CrashNotifier.notifyCrash(service: displayName, serviceID: config.name, exitCode: code)
                }
                : nil
            return ServiceController(config: config, cwd: cwd, onCrash: onCrash)
        }
        if pollingEnabled { startPolling() }
    }

    /// Porta l'attenzione su un servizio: espande il suo terminale e filtra sugli errori.
    /// Usato dal deep-link della notifica di crash (match su config.name).
    func revealService(named name: String) {
        guard let service = services.first(where: { $0.config.name == name }) else { return }
        expandedServices.insert(service.id)
        service.logs.levelFilter = .errors
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

    func start(profile: LaunchProfile) {
        if !natsUp { showNATSWarning = true }
        for service in services
        where profile.serviceNames.contains(service.config.name) && !service.processAlive {
            service.start()
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
