import Foundation
import Observation

/// Radice dello stato dell'app: tutti i controller + spia NATS + azioni globali.
@MainActor
@Observable
final class AppModel {
    let services: [ServiceController]
    private(set) var natsUp = false
    var showNATSWarning = false

    private var pollTask: Task<Void, Never>?

    /// `cwd`, `pollingEnabled` e `crashNotificationsEnabled` iniettabili solo per i test.
    init(configs: [ServiceConfig] = ServiceConfig.all,
         cwd: String? = nil,
         pollingEnabled: Bool = true,
         crashNotificationsEnabled: Bool = true) {
        let onCrash: ((String, Int32) -> Void)? = crashNotificationsEnabled
            ? { name, code in CrashNotifier.notifyCrash(service: name, exitCode: code) }
            : nil
        services = configs.map { ServiceController(config: $0, cwd: cwd, onCrash: onCrash) }
        if pollingEnabled { startPolling() }
    }

    var anyRunning: Bool { services.contains { $0.processAlive } }

    func startAll() {
        if !natsUp { showNATSWarning = true }  // avvisa ma procedi (spec)
        for service in services where !service.processAlive {
            service.start()
        }
    }

    func stopAll() {
        for service in services { service.stop() }
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
