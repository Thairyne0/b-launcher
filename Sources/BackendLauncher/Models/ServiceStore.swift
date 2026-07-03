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
    /// Nome SF Symbol da mostrare al posto dell'icona di default. `nil` = default.
    /// Additivo (schema resta v1): assente in un file scritto da una versione precedente
    /// dell'app, decodifica a `nil` grazie al default qui sotto.
    var symbolName: String? = nil
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
    /// Colore accento del progetto in UI, es. "#4F8EF7". `nil` = colore di default.
    /// Additivo (schema resta v1): assente in un file scritto da una versione precedente
    /// dell'app, decodifica a `nil` grazie al default qui sotto.
    var accentColorHex: String? = nil
    var id: String { name }
}

struct StoreFile: Codable {
    var version: Int
    var projects: [StoredProject]
}

/// Errori di validazione delle mutazioni dello store: nomi duplicati (progetto/servizio,
/// confronto case-insensitive) o progetto non trovato.
enum StoreError: LocalizedError, Equatable {
    case duplicateProjectName(String)
    case duplicateServiceName(String)
    case projectNotFound(String)
    case duplicateProfileName(String)
    case unknownServiceInProfile(profile: String, service: String)

    var errorDescription: String? {
        switch self {
        case .duplicateProjectName(let name):
            "Esiste già un progetto chiamato \"\(name)\"."
        case .duplicateServiceName(let name):
            "Esiste già un servizio chiamato \"\(name)\" in questo progetto."
        case .projectNotFound(let id):
            "Progetto \"\(id)\" non trovato."
        case .duplicateProfileName(let name):
            "Esiste già un profilo chiamato \"\(name)\" in questo progetto."
        case .unknownServiceInProfile(let profile, let service):
            "Il profilo \"\(profile)\" fa riferimento al servizio \"\(service)\", che non esiste in questo progetto."
        }
    }
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
        var preservationFailed = false

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
                        // Preservazione fallita: NON scrivere su disco in questa sessione,
                        // altrimenti sovrascriveremmo proprio i dati che volevamo salvare.
                        print("[ServiceStore] impossibile preservare il file di versione futura: \(error)")
                        preservationFailed = true
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
                    // Stessa logica del file di versione futura: niente save() se il
                    // backup non è riuscito, per non distruggere l'originale.
                    print("[ServiceStore] impossibile mettere da parte il file corrotto: \(error)")
                    preservationFailed = true
                }
            }
        }

        self.projects = [Self.migrateFromLegacy()]
        if preservationFailed {
            // Store solo in memoria per questa sessione: il file originale resta
            // intatto sul disco per un retry o un intervento manuale.
            print("[ServiceStore] save() saltato: backup del file precedente non riuscito")
        } else {
            save()
        }
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

    // MARK: - Mutazioni (wizard add/edit/delete — Phase D)

    /// Crea un nuovo progetto vuoto. Nome normalizzato (trim), non vuoto, univoco
    /// (case-insensitive) tra i progetti esistenti. Salva su disco se riesce.
    func addProject(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.duplicateProjectName(name) }
        guard !projects.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw StoreError.duplicateProjectName(trimmed)
        }
        projects.append(StoredProject(name: trimmed, services: [], profiles: [], infraCheck: nil))
        save()
    }

    /// Rimuove un progetto per id (nome). No-op silenzioso se non trovato (idempotente per
    /// il chiamante — la UI non deve gestire un caso "già rimosso").
    func removeProject(id: String) {
        projects.removeAll { $0.id == id }
        save()
    }

    /// Aggiunge un servizio a un progetto esistente. Nome univoco (case-insensitive)
    /// all'interno del progetto.
    func addService(_ service: StoredService, toProject id: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw StoreError.projectNotFound(id)
        }
        guard !projects[index].services.contains(where: {
            $0.name.caseInsensitiveCompare(service.name) == .orderedSame
        }) else {
            throw StoreError.duplicateServiceName(service.name)
        }
        projects[index].services.append(service)
        save()
    }

    /// Aggiorna (ed eventualmente rinomina) un servizio esistente. Se il nuovo nome
    /// differisce dal vecchio, la nuova unicità viene ri-verificata tra gli altri servizi
    /// del progetto (il servizio stesso è escluso dal controllo).
    ///
    /// ATTENZIONE — semantica del rename: lo store non ha alcuna nozione di "processo in
    /// esecuzione" (quello vive in `ServiceController`/`AppModel`). Un rename si propaga a
    /// `AppModel.reloadFromStore()` come id namespaced cambiato ("progetto/vecchioNome" →
    /// "progetto/nuovoNome"), quindi **remove del controller vecchio + add di uno nuovo**, non
    /// un update in-place. Se il servizio è in esecuzione al momento del rename, il processo
    /// verrebbe fermato silenziosamente. La UI (`ServiceFormSheet`) impone questo fermando/
    /// disabilitando la modifica mentre il servizio è vivo; qualunque altro chiamante
    /// programmatico di `updateService` con un rename effettivo DEVE verificare da sé che il
    /// servizio non sia in esecuzione prima di chiamare questo metodo.
    func updateService(named oldName: String, inProject id: String, with service: StoredService) throws {
        guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else {
            throw StoreError.projectNotFound(id)
        }
        guard let serviceIndex = projects[projectIndex].services.firstIndex(where: {
            $0.name.caseInsensitiveCompare(oldName) == .orderedSame
        }) else {
            throw StoreError.projectNotFound(id)
        }
        let collision = projects[projectIndex].services.enumerated().contains { index, existing in
            index != serviceIndex && existing.name.caseInsensitiveCompare(service.name) == .orderedSame
        }
        guard !collision else { throw StoreError.duplicateServiceName(service.name) }
        projects[projectIndex].services[serviceIndex] = service
        save()
    }

    /// Rinomina un progetto. Nome normalizzato (trim), non vuoto, univoco (case-insensitive)
    /// tra gli ALTRI progetti. `projectNotFound` se `id` non corrisponde a nessun progetto.
    ///
    /// ATTENZIONE — semantica del rename: `StoredProject.id` == `name`, quindi rinominare
    /// cambia anche l'id del progetto. Gli id namespaced dei suoi servizi in `AppModel`
    /// ("VecchioNome/svc" → "NuovoNome/svc") cambiano di conseguenza: il chiamante DEVE
    /// invocare `AppModel.reloadFromStore()` dopo questa chiamata. Per `reloadFromStore()`
    /// un id namespaced cambiato è indistinguibile da "rimuovi il vecchio, aggiungi il nuovo"
    /// (stessa semantica di `updateService` con rename) — un servizio del progetto rinominato
    /// in esecuzione al momento del reload verrà quindi FERMATO. Eventuali selezioni persistite
    /// altrove (es. chip di focus UI) che referenziano l'id vecchio si "auto-guariscono"
    /// semplicemente sparendo (comportamento accettato, non un bug).
    func renameProject(id: String, to newName: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw StoreError.projectNotFound(id)
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.duplicateProjectName(newName) }
        let collision = projects.enumerated().contains { otherIndex, project in
            otherIndex != index && project.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !collision else { throw StoreError.duplicateProjectName(trimmed) }
        projects[index].name = trimmed
        save()
    }

    /// Ribasa le directory dei servizi di un progetto su una nuova root. La root comune
    /// CORRENTE viene calcolata dalle directory esistenti (stessa euristica dell'export
    /// template, `ProjectTemplateCodec.commonRoot`); ogni servizio la cui directory ricade
    /// sotto quella root comune viene ribasato su `newRoot` preservando il suffisso relativo.
    /// Servizi la cui directory è FUORI dalla root comune (o se non esiste una root comune,
    /// es. un solo servizio con directory diversa da tutte le altre) restano INVARIATI
    /// (path assoluto originale preservato — comportamento esplicito, non un bug: non
    /// c'è modo sicuro di dedurre dove ribasarli). `projectNotFound` se `id` non esiste.
    func rebaseProject(id: String, ontoRoot newRoot: URL) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw StoreError.projectNotFound(id)
        }
        projects[index].services = Self.rebasedServices(
            projects[index].services,
            ontoRoot: newRoot
        )
        save()
    }

    /// Logica pura di rebase, testabile senza istanziare uno store: calcola la root comune
    /// delle directory correnti e ribasa ogni servizio che vi ricade sotto su `newRoot`.
    static func rebasedServices(_ services: [StoredService], ontoRoot newRoot: URL) -> [StoredService] {
        guard let commonRoot = ProjectTemplateCodec.commonRoot(forServiceDirectories: services.map(\.directory)) else {
            return services
        }
        let standardizedCommonRoot = commonRoot.standardizedFileURL.path
        let commonRootWithSlash = standardizedCommonRoot.hasSuffix("/") ? standardizedCommonRoot : standardizedCommonRoot + "/"
        return services.map { service in
            var updated = service
            let standardizedDirectory = URL(fileURLWithPath: service.directory).standardizedFileURL.path
            if standardizedDirectory == standardizedCommonRoot {
                updated.directory = newRoot.standardizedFileURL.path
            } else if standardizedDirectory.hasPrefix(commonRootWithSlash) {
                let suffix = String(standardizedDirectory.dropFirst(commonRootWithSlash.count))
                updated.directory = newRoot.appendingPathComponent(suffix).standardizedFileURL.path
            }
            // Fuori dalla root comune: invariato (documentato).
            return updated
        }
    }

    /// Imposta, sostituisce o rimuove (con `nil`) l'infra check di un progetto (es. NATS).
    /// `projectNotFound` se `projectID` non esiste.
    func updateInfraCheck(projectID: String, infraCheck: StoredInfraCheck?) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw StoreError.projectNotFound(projectID)
        }
        projects[index].infraCheck = infraCheck
        save()
    }

    /// Imposta, sostituisce o rimuove (con `nil`) il colore accento di un progetto.
    /// `projectNotFound` se `projectID` non esiste.
    func updateProjectAccentColor(projectID: String, hex: String?) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw StoreError.projectNotFound(projectID)
        }
        projects[index].accentColorHex = hex
        save()
    }

    /// Sostituisce l'intera lista di profili di un progetto. Validazione:
    /// - ogni nome profilo non vuoto (dopo trim) e univoco (case-insensitive) tra i profili
    ///   passati;
    /// - ogni `serviceNames` deve fare riferimento solo a nomi di servizio ESISTENTI nel
    ///   progetto (altrimenti `.unknownServiceInProfile`).
    /// `projectNotFound` se `projectID` non esiste. Su validazione fallita, lo store resta
    /// invariato (nessuna scrittura parziale).
    func updateProfiles(projectID: String, profiles: [StoredProfile]) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw StoreError.projectNotFound(projectID)
        }
        var seenNames: Set<String> = []
        for profile in profiles {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw StoreError.duplicateProfileName(profile.name) }
            let normalized = trimmed.lowercased()
            guard !seenNames.contains(normalized) else {
                throw StoreError.duplicateProfileName(trimmed)
            }
            seenNames.insert(normalized)
        }
        let serviceNames = Set(projects[index].services.map { $0.name.lowercased() })
        for profile in profiles {
            for serviceName in profile.serviceNames {
                guard serviceNames.contains(serviceName.lowercased()) else {
                    throw StoreError.unknownServiceInProfile(profile: profile.name, service: serviceName)
                }
            }
        }
        projects[index].profiles = profiles
        save()
    }

    /// Rimuove un servizio da un progetto. No-op silenzioso se progetto/servizio non trovati.
    func removeService(named name: String, fromProject id: String) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[projectIndex].services.removeAll {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        save()
    }

    // MARK: - Template export/import (Phase E)

    /// Esporta un progetto come `ProjectTemplate` serializzato (JSON pretty-printed), con le
    /// directory dei servizi rese relative a `root`. Lancia `.projectNotFound` se l'id non
    /// corrisponde a nessun progetto.
    func exportTemplate(projectID: String, root: URL) throws -> Data {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw StoreError.projectNotFound(projectID)
        }
        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)
        return try ProjectTemplateCodec.encode(template)
    }

    /// Importa un template: decodifica, ribasa le directory relative su `root`, ed effettua
    /// l'append allo store con la stessa semantica di unicità di `addProject` (nome
    /// case-insensitive univoco — su collisione la UI può richiamare con `nameOverride`).
    /// Su successo, persiste e ritorna il progetto creato.
    @discardableResult
    func importTemplate(_ data: Data, root: URL, nameOverride: String? = nil) throws -> StoredProject {
        let template = try ProjectTemplateCodec.decode(data)
        let project = try ProjectTemplateCodec.makeProject(from: template, root: root, nameOverride: nameOverride)
        guard !projects.contains(where: { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else {
            throw StoreError.duplicateProjectName(project.name)
        }
        projects.append(project)
        save()
        return project
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
                absoluteDirectory: URL(fileURLWithPath: service.directory),
                projectName: project.name,
                accentColorHex: project.accentColorHex,
                symbolName: service.symbolName
            )
        }
    }
}
