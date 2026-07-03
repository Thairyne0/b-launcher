import Foundation
import Observation

// MARK: - Schema persistito (versione 1)

struct StoredReadiness: Codable, Hashable {
    enum Kind: String, Codable {
        case port
        case logMarker
        case processAlive
    }
    var kind: Kind
    var port: UInt16?
    var marker: String?
}

struct StoredService: Codable, Hashable {
    var name: String
    var directory: String          // path assoluto della cartella del servizio
    var command: String
    var readiness: StoredReadiness
}

struct StoredInfraCheck: Codable, Hashable {
    var label: String
    var port: UInt16
}

struct StoredProfile: Codable, Hashable {
    var name: String
    var serviceNames: [String]
}

struct StoredProject: Codable, Hashable, Identifiable {
    var name: String
    var services: [StoredService]
    var profiles: [StoredProfile]
    var infraCheck: StoredInfraCheck?
    var id: String { name }
}

struct StoreFile: Codable {
    var version: Int
    var projects: [StoredProject]
}

/// Store persistente dei progetti/servizi. Sostituisce gradualmente la configurazione
/// statica di `ServiceConfig`: al primo avvio (nessun file su disco) migra automaticamente
/// la configurazione legacy "Skillera" hardcoded, poi vive interamente su disco.
@MainActor
@Observable
final class ServiceStore {
    private(set) var projects: [StoredProject]

    private let fileURL: URL

    private static let currentVersion = 1

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("BackendLauncher").appendingPathComponent("services.json")
    }

    /// `fileURL` iniettabile per i test; in produzione usa `~/Library/Application Support/BackendLauncher/services.json`.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultFileURL
        self.fileURL = url

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            // Se non riusciamo nemmeno a creare la directory, non c'è molto altro da fare:
            // il successivo tentativo di scrittura fallirà silenziosamente (best-effort).
            print("[ServiceStore] impossibile creare la directory di \(url.path): \(error)")
        }

        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(StoreFile.self, from: data) {
                if decoded.version > Self.currentVersion {
                    // File scritto da una versione futura dell'app: NON trattarlo come v1
                    // (schema potenzialmente incompatibile) e NON sovrascriverlo — mettilo
                    // da parte così un downgrade non perde silenziosamente i dati dell'utente.
                    print("[ServiceStore] trovato services.json con version \(decoded.version) > \(Self.currentVersion) (corrente): preservato, ricado sulla migrazione")
                    let futureVersionURL = url.appendingPathExtension("futureversion")
                    try? FileManager.default.removeItem(at: futureVersionURL)
                    do {
                        try FileManager.default.moveItem(at: url, to: futureVersionURL)
                    } catch {
                        print("[ServiceStore] impossibile preservare il file di versione futura: \(error)")
                    }
                } else {
                    self.projects = decoded.projects
                    return
                }
            } else {
                // File presente ma non decodificabile: mettilo da parte e ricadi sulla migrazione.
                let corruptURL = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: corruptURL)
                do {
                    try FileManager.default.moveItem(at: url, to: corruptURL)
                } catch {
                    print("[ServiceStore] impossibile mettere da parte il file corrotto: \(error)")
                }
            }
        }

        self.projects = [Self.migrateFromLegacy()]
        save()
    }

    /// Costruisce il progetto "Skillera" dalla configurazione legacy hardcoded.
    private static func migrateFromLegacy() -> StoredProject {
        let services = ServiceConfig.legacyAll.map { config -> StoredService in
            let readiness: StoredReadiness
            if let port = config.port {
                readiness = StoredReadiness(kind: .port, port: port, marker: nil)
            } else {
                readiness = StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started")
            }
            return StoredService(
                name: config.name,
                directory: ServiceConfig.projectRoot.appendingPathComponent(config.directory).path,
                command: config.command,
                readiness: readiness
            )
        }

        let profiles = ServiceConfig.legacyProfiles.map {
            StoredProfile(name: $0.name, serviceNames: $0.serviceNames)
        }

        return StoredProject(
            name: "Skillera",
            services: services,
            profiles: profiles,
            infraCheck: StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort)
        )
    }

    /// Primo progetto: interfaccia utente a singolo progetto per ora (Phase A).
    var activeProject: StoredProject? { projects.first }

    /// Sostituisce un progetto esistente (match su `id`/`name`) con una versione aggiornata.
    func replaceProject(_ project: StoredProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    /// Scrittura atomica, JSON pretty-printed con chiavi ordinate per diff stabili.
    func save() {
        let file = StoreFile(version: Self.currentVersion, projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            print("[ServiceStore] impossibile serializzare lo store in JSON")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ServiceStore] impossibile scrivere \(fileURL.path): \(error)")
        }
    }

    /// Bridge verso il tipo runtime `ServiceConfig` usato da `ServiceController`.
    /// Fase B: mappa `StoredReadiness` direttamente su `ReadinessProbe` — il marker persistito
    /// su disco sopravvive intatto (non più forzato all'hardcoded "successfully started").
    func serviceConfigs(for project: StoredProject) -> [ServiceConfig] {
        project.services.map { service in
            let readiness: ReadinessProbe
            switch service.readiness.kind {
            case .port:
                readiness = .tcpPort(service.readiness.port ?? 0)
            case .logMarker:
                readiness = .logMarker(service.readiness.marker ?? "successfully started")
            case .processAlive:
                readiness = .processAlive
            }
            return ServiceConfig(
                name: service.name,
                directory: "",
                command: service.command,
                readiness: readiness,
                absoluteDirectory: URL(fileURLWithPath: service.directory)
            )
        }
    }
}
