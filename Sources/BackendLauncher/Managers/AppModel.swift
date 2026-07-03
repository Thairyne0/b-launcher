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

    private var pollTask: Task<Void, Never>?

    /// `cwd`, `pollingEnabled` e `crashNotificationsEnabled` iniettabili solo per i test.
    init(configs: [ServiceConfig] = ServiceConfig.all,
         cwd: String? = nil,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
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
                let ports = [ServiceConfig.natsPort] + self.services.compactMap(\.config.port)
                let results = await Self.checkPorts(ports)
                self.natsUp = results[ServiceConfig.natsPort] ?? false
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
