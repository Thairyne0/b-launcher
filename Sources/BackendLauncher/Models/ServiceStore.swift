import CryptoKit
import Foundation
import Observation

// MARK: - Schema persistito (versione 1)

struct StoredReadiness: Codable, Hashable {
    enum Kind: String, Codable {
        case port
        case logMarker
        case processAlive
        /// GET su `http://127.0.0.1:<port><path>` → 2xx = pronto. Richiede schema v2:
        /// un'app vecchia non saprebbe decodificare questo `kind` (vedi `versionRequired`).
        case httpHealth
    }
    var kind: Kind
    var port: UInt16?
    var marker: String?
    /// Path del health check (solo `kind == .httpHealth`), es. "/health". Additivo:
    /// assente nei file vecchi → `nil`.
    var path: String? = nil
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
    /// `true` = questo backend non usa un file `.env`: il badge/icona ".env mancante" va
    /// nascosto. Optional e non Bool secco per l'additività dello schema (v1): assente nei
    /// file vecchi → `nil` → trattato come `false` dal bridge.
    var envBadgeDisabled: Bool? = nil
    /// Path assoluto di un file env ALTERNATIVO (es. `.env.staging`): letto allo spawn e
    /// iniettato nell'ambiente del processo — il `.env` su disco resta intatto (vincolo
    /// non-invasivo). Additivo: assente nei file vecchi → `nil`. NON esportato nei
    /// template (path assoluto personale).
    var envFile: String? = nil
    /// Nomi di servizi dello STESSO progetto che devono essere pronti prima che questo
    /// parta (avvio orchestrato a ondate). Richiede schema v2 quando usato — vedi
    /// `versionRequired`. Nomi sconosciuti/stantii vengono ignorati a runtime.
    var startAfter: [String]? = nil
    /// URL dell'app servita (frontend web, o doc API di un backend): abilita il bottone
    /// "apri nel browser" sulla card e l'apertura automatica a fine "Avvia stack".
    /// Additivo; esportato nei template (localhost è portabile).
    var appURL: String? = nil
    /// `true` = app principale del progetto ("Avvia stack" la fa partire per ultima,
    /// a stack pronto). Al più UNA per progetto — lo store la fa rispettare.
    var isMainApp: Bool? = nil
    /// Comandi alternativi one-shot (es. `flutter run -d iphone` / `-d chrome`, o uno
    /// script di debug): menu "Avvia con…" sulla card. Il comando di default resta
    /// invariato. Additivo; esportato nei template.
    var commandVariants: [String]? = nil
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
    /// Presente quando il progetto è stato importato da un template `.blauncher.json` che vive
    /// DENTRO la root del progetto stesso (tipico: template committato dal team nel repo).
    /// Permette di rilevare quando il file è cambiato (es. dopo un `git pull`) e offrire una
    /// risincronizzazione. Additivo (schema resta v1): assente in un file scritto da una
    /// versione precedente dell'app, decodifica a `nil` grazie al default qui sotto.
    var templateSync: TemplateSyncInfo? = nil
    var id: String { name }
}

/// Traccia il template `.blauncher.json` da cui un progetto è stato importato, per rilevare
/// modifiche successive (es. un collega ha aggiornato il template e l'utente ha fatto `git
/// pull`). `fileRelativePath` è relativo alla root del progetto (stessa root calcolata da
/// `ProjectTemplateCodec.commonRoot` sulle directory dei servizi correnti), non alla directory
/// di un singolo servizio.
struct TemplateSyncInfo: Codable, Hashable {
    var fileRelativePath: String
    var lastImportedHash: String
}

/// Hashing puro (nessuna dipendenza da `ServiceStore`) per confrontare i contenuti di un
/// template `.blauncher.json` tra l'import e un successivo controllo di sincronizzazione.
/// SHA256 esadecimale minuscolo — stabile, non serve altro che rilevare "è cambiato qualcosa".
enum TemplateSyncHasher {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Esito di `ServiceStore.checkTemplateSync(projectID:)`.
enum TemplateSyncStatus: Equatable {
    /// Il progetto non è tracciato (nessun `templateSync`, es. creato manualmente o importato
    /// da una versione dell'app precedente a questa feature).
    case notTracked
    /// Il file del template esiste ancora e il suo hash coincide con l'ultimo importato.
    case upToDate
    /// Il file del template esiste ma il contenuto è cambiato rispetto all'ultimo import.
    case changed(newHash: String)
    /// Il file del template non esiste più al path relativo tracciato (root mancante, file
    /// rinominato/rimosso, ecc.).
    case fileMissing
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
            "Esiste già un backend chiamato \"\(name)\" in questo progetto."
        case .projectNotFound(let id):
            "Progetto \"\(id)\" non trovato."
        case .duplicateProfileName(let name):
            "Esiste già un profilo chiamato \"\(name)\" in questo progetto."
        case .unknownServiceInProfile(let profile, let service):
            "Il profilo \"\(profile)\" fa riferimento al backend \"\(service)\", che non esiste in questo progetto."
        }
    }
}

/// Store persistente dei progetti/servizi, interamente su disco. Un'installazione nuova
/// (nessun `services.json`) parte VUOTA: l'onboarding è la schermata di benvenuto +
/// "Aggiungi progetto", non contenuto hardcoded. (Fino al 2026-07-04 il primo avvio
/// migrava un progetto "Skillera" coi path del Mac dell'autore — rimosso: su qualsiasi
/// altra macchina era solo un progetto rotto da eliminare.)
@MainActor
@Observable
final class ServiceStore {
    private(set) var projects: [StoredProject]

    private let fileURL: URL

    /// Massima versione di schema che QUESTA app sa leggere.
    private static let currentVersion = 2

    /// Versione minima che un lettore deve capire per questo contenuto: 2 solo se almeno un
    /// servizio usa `httpHealth` (kind sconosciuto alle app v1), altrimenti 1 — così un file
    /// che non usa feature nuove resta leggibile anche dopo un downgrade dell'app.
    static func versionRequired(for projects: [StoredProject]) -> Int {
        let usesV2Features = projects.contains { project in
            project.services.contains {
                $0.readiness.kind == .httpHealth || !($0.startAfter ?? []).isEmpty
            }
        }
        return usesV2Features ? 2 : 1
    }

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

        self.projects = []
        if preservationFailed {
            // Store solo in memoria per questa sessione: il file originale resta
            // intatto sul disco per un retry o un intervento manuale.
            print("[ServiceStore] save() saltato: backup del file precedente non riuscito")
        } else {
            save()
        }
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
        enforceSingleMainApp(projectIndex: index, keeping: service.name)
        save()
    }

    /// Al più UNA app principale per progetto: se `keeping` è flaggata, sflagga le altre.
    private func enforceSingleMainApp(projectIndex: Int, keeping serviceName: String) {
        guard projects[projectIndex].services.first(where: {
            $0.name.caseInsensitiveCompare(serviceName) == .orderedSame
        })?.isMainApp == true else { return }
        for index in projects[projectIndex].services.indices
        where projects[projectIndex].services[index].name.caseInsensitiveCompare(serviceName) != .orderedSame {
            projects[projectIndex].services[index].isMainApp = nil
        }
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
        enforceSingleMainApp(projectIndex: projectIndex, keeping: service.name)
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
    ///
    /// `sourceFileURL`, se fornito e ricade DENTRO `root` (il template vive nel repo del team,
    /// non altrove sul disco es. Downloads), imposta `templateSync` sul progetto creato: path
    /// relativo a `root` + hash SHA256 del contenuto importato. Questo abilita
    /// `checkTemplateSync`/`syncProjectFromTemplate` a rilevare aggiornamenti futuri del file
    /// (es. dopo un `git pull` che porta una nuova versione del template committata dal team).
    /// Fuori da `root`, o `nil`: `templateSync` resta `nil` (progetto non tracciato).
    @discardableResult
    func importTemplate(_ data: Data, root: URL, nameOverride: String? = nil, sourceFileURL: URL? = nil) throws -> StoredProject {
        let template = try ProjectTemplateCodec.decode(data)
        var project = try ProjectTemplateCodec.makeProject(from: template, root: root, nameOverride: nameOverride)
        guard !projects.contains(where: { $0.name.caseInsensitiveCompare(project.name) == .orderedSame }) else {
            throw StoreError.duplicateProjectName(project.name)
        }
        if let sourceFileURL, let relativePath = Self.relativePathIfInside(fileURL: sourceFileURL, root: root) {
            project.templateSync = TemplateSyncInfo(fileRelativePath: relativePath, lastImportedHash: TemplateSyncHasher.hash(data))
        }
        projects.append(project)
        save()
        return project
    }

    /// `nil` se `fileURL` non ricade sotto `root` (standardizzati entrambi), altrimenti il
    /// suffisso relativo (senza slash iniziale).
    private static func relativePathIfInside(fileURL: URL, root: URL) -> String? {
        let standardizedFile = fileURL.standardizedFileURL.path
        let standardizedRoot = root.standardizedFileURL.path
        let rootWithSlash = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        guard standardizedFile.hasPrefix(rootWithSlash) else { return nil }
        return String(standardizedFile.dropFirst(rootWithSlash.count))
    }

    // MARK: - Template sync dal team (post-import)

    /// Calcola lo stato di sincronizzazione del template da cui `projectID` è stato importato,
    /// rileggendo il file dal disco alla root corrente del progetto (calcolata come
    /// `ProjectTemplateCodec.commonRoot` delle directory attuali dei suoi servizi — stessa
    /// euristica usata dall'export/rebase, così un progetto ribasato su un nuovo Mac continua a
    /// essere tracciato correttamente).
    func checkTemplateSync(projectID: String) -> TemplateSyncStatus {
        guard let project = projects.first(where: { $0.id == projectID }),
              let sync = project.templateSync else {
            return .notTracked
        }
        guard let root = ProjectTemplateCodec.commonRoot(forServiceDirectories: project.services.map(\.directory)) else {
            return .fileMissing
        }
        let fileURL = root.appendingPathComponent(sync.fileRelativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            return .fileMissing
        }
        let currentHash = TemplateSyncHasher.hash(data)
        return currentHash == sync.lastImportedHash ? .upToDate : .changed(newHash: currentHash)
    }

    /// Errori di `syncProjectFromTemplate`, distinti da `StoreError` perché riflettono lo stato
    /// del file sul disco (non una violazione di invarianti dello store).
    enum TemplateSyncError: LocalizedError, Equatable {
        case notTracked
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .notTracked:
                "Questo progetto non è collegato a un template di team."
            case .fileMissing:
                "Il file del template non è più presente nella cartella del progetto."
            }
        }
    }

    /// Rilegge il template tracciato dal disco e SOSTITUISCE servizi/profili/infraCheck del
    /// progetto esistente con quelli ricostruiti dal template aggiornato (stessa root — i path
    /// assoluti dei servizi restano quelli già in uso su questo Mac). Nome e colore accento del
    /// progetto sono PRESERVATI (il template non li conosce/non deve poterli sovrascrivere).
    /// Aggiorna anche `lastImportedHash`. Il chiamante deve invocare `AppModel.reloadFromStore()`
    /// dopo — stessa semantica di ogni altra mutazione dello store che tocca `services`.
    func syncProjectFromTemplate(projectID: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            throw StoreError.projectNotFound(projectID)
        }
        guard let sync = projects[index].templateSync else {
            throw TemplateSyncError.notTracked
        }
        guard let root = ProjectTemplateCodec.commonRoot(forServiceDirectories: projects[index].services.map(\.directory)) else {
            throw TemplateSyncError.fileMissing
        }
        let fileURL = root.appendingPathComponent(sync.fileRelativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            throw TemplateSyncError.fileMissing
        }
        let template = try ProjectTemplateCodec.decode(data)
        let rebuilt = try ProjectTemplateCodec.makeProject(from: template, root: root, nameOverride: projects[index].name)

        var updated = projects[index]
        updated.services = rebuilt.services
        updated.profiles = rebuilt.profiles
        updated.infraCheck = rebuilt.infraCheck
        updated.templateSync = TemplateSyncInfo(fileRelativePath: sync.fileRelativePath, lastImportedHash: TemplateSyncHasher.hash(data))
        replaceProject(updated)
        save()
    }

    /// Scrittura atomica, JSON pretty-printed con chiavi ordinate per diff stabili.
    func save() {
        let file = StoreFile(version: Self.versionRequired(for: projects), projects: projects)
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
            case .httpHealth:
                readiness = .httpHealth(port: service.readiness.port ?? 0,
                                        path: service.readiness.path ?? "/health")
            }
            var config = ServiceConfig(
                name: service.name,
                directory: "",
                command: service.command,
                readiness: readiness,
                absoluteDirectory: URL(fileURLWithPath: service.directory),
                projectName: project.name,
                accentColorHex: project.accentColorHex,
                symbolName: service.symbolName
            )
            config.envBadgeDisabled = service.envBadgeDisabled ?? false
            config.envFile = service.envFile
            config.startAfter = service.startAfter ?? []
            config.appURL = service.appURL
            config.isMainApp = service.isMainApp ?? false
            config.commandVariants = service.commandVariants ?? []
            return config
        }
    }
}
