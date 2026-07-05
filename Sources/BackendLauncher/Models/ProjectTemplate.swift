import Foundation

/// Template esportabile/condivisibile di un progetto: stessa forma di `StoredProject` ma con
/// le directory dei servizi rese RELATIVE a una root scelta all'export, così un collega può
/// re-importarlo puntando alla propria copia locale del repo (path assoluti diversi).
struct ProjectTemplate: Codable {
    var templateVersion: Int   // = 1
    var name: String
    var services: [TemplateService]
    var profiles: [StoredProfile]
    var infraCheck: StoredInfraCheck?

    struct TemplateService: Codable {
        var name: String
        var relativeDirectory: String   // relativo alla root scelta all'export
        var command: String
        var readiness: StoredReadiness
        /// Additivo: assente nei template vecchi → `nil`; le app vecchie che leggono un
        /// template nuovo ignorano la chiave sconosciuta (nessun bump di versione).
        var envBadgeDisabled: Bool? = nil
        /// Dipendenze di avvio (nomi nello stesso template). Se presente e non vuota,
        /// il template dichiara version 2 — vedi `versionRequired`.
        var startAfter: [String]? = nil
    }
}

/// Errori di decodifica/encoding del template.
enum ProjectTemplateError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unsafeRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Questo template è stato creato da una versione più recente dell'app (versione \(version)): aggiorna Backend Launcher per importarlo."
        case .unsafeRelativePath(let path):
            "Il template contiene un percorso non sicuro (\"\(path)\"): i percorsi relativi non possono uscire dalla cartella scelta."
        }
    }
}

/// Funzioni pure di conversione `StoredProject` <-> `ProjectTemplate` e (de)serializzazione JSON.
/// Nessuno stato — completamente testabile senza `ServiceStore`.
enum ProjectTemplateCodec {
    /// Marker-prefisso usato quando la directory di un servizio non ricade sotto `root`:
    /// preserviamo il path assoluto invece di produrre un relativo insensato (es. "../../../x").
    static let absoluteMarkerPrefix = "abs:"

    /// Massima versione di template che QUESTA app sa leggere.
    private static let currentVersion = 2

    /// Versione minima dichiarata nel template: 2 solo se serve (readiness `httpHealth`,
    /// sconosciuta alle app v1), altrimenti 1 — un collega con l'app vecchia importa senza
    /// problemi i template che non usano feature nuove.
    static func versionRequired(for services: [ProjectTemplate.TemplateService]) -> Int {
        services.contains {
            $0.readiness.kind == .httpHealth || !($0.startAfter ?? []).isEmpty
        } ? 2 : 1
    }

    /// Export: calcola i path relativi rispetto a `root`. Servizi FUORI da root → path
    /// assoluto preservato con prefisso marker "abs:" (fallback esplicito, documentato).
    static func makeTemplate(from project: StoredProject, root: URL) -> ProjectTemplate {
        let standardizedRoot = root.standardizedFileURL.path
        let services = project.services.map { service -> ProjectTemplate.TemplateService in
            ProjectTemplate.TemplateService(
                name: service.name,
                relativeDirectory: relativePath(forServiceDirectory: service.directory, root: standardizedRoot),
                command: service.command,
                readiness: service.readiness,
                envBadgeDisabled: service.envBadgeDisabled,
                startAfter: service.startAfter
            )
        }
        return ProjectTemplate(
            templateVersion: versionRequired(for: services),
            name: project.name,
            services: services,
            profiles: project.profiles,
            infraCheck: project.infraCheck
        )
    }

    /// Import: ricostruisce `StoredProject` risolvendo i relativi su `root`; le entry
    /// "abs:"-prefixed vengono usate as-is (assolute). Il nome del progetto può essere
    /// sovrascritto (utile in caso di collisione col nome esistente).
    /// I path relativi con componenti ".." vengono RIFIUTATI: un template artigianale
    /// non deve poter risolvere directory fuori dalla root scelta dall'utente.
    static func makeProject(from template: ProjectTemplate, root: URL, nameOverride: String?) throws -> StoredProject {
        let standardizedRoot = root.standardizedFileURL
        let services = try template.services.map { templateService -> StoredService in
            let relative = templateService.relativeDirectory
            if !relative.hasPrefix(absoluteMarkerPrefix),
               relative.components(separatedBy: "/").contains("..") {
                throw ProjectTemplateError.unsafeRelativePath(relative)
            }
            return StoredService(
                name: templateService.name,
                directory: resolvedDirectory(relativeDirectory: relative, root: standardizedRoot),
                command: templateService.command,
                readiness: templateService.readiness,
                envBadgeDisabled: templateService.envBadgeDisabled,
                startAfter: templateService.startAfter
            )
        }
        let name = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? nameOverride!.trimmingCharacters(in: .whitespacesAndNewlines)
            : template.name
        return StoredProject(
            name: name,
            services: services,
            profiles: template.profiles,
            infraCheck: template.infraCheck
        )
    }

    /// Encoding pretty-printed con chiavi ordinate, per diff stabili (stesso stile di `ServiceStore.save()`).
    static func encode(_ template: ProjectTemplate) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(template)
    }

    /// Decodifica con controllo esplicito di `templateVersion`: un template scritto da una
    /// versione futura dell'app (schema potenzialmente incompatibile) produce un errore
    /// chiaro invece di un decode silenziosamente parziale/sbagliato.
    static func decode(_ data: Data) throws -> ProjectTemplate {
        let template = try JSONDecoder().decode(ProjectTemplate.self, from: data)
        guard template.templateVersion <= currentVersion else {
            throw ProjectTemplateError.unsupportedVersion(template.templateVersion)
        }
        return template
    }

    // MARK: - Path rebasing

    /// Se `directory` ricade sotto `root` (standardizzato), ritorna il suffisso relativo
    /// (senza slash iniziale). Altrimenti ritorna il path assoluto con prefisso "abs:".
    private static func relativePath(forServiceDirectory directory: String, root: String) -> String {
        let standardizedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if standardizedDirectory == root {
            return ""
        }
        if standardizedDirectory.hasPrefix(rootWithSlash) {
            return String(standardizedDirectory.dropFirst(rootWithSlash.count))
        }
        return absoluteMarkerPrefix + standardizedDirectory
    }

    /// Risolve una entry di template (relativa o "abs:"-prefixed) su una root scelta all'import.
    private static func resolvedDirectory(relativeDirectory: String, root: URL) -> String {
        if relativeDirectory.hasPrefix(absoluteMarkerPrefix) {
            return String(relativeDirectory.dropFirst(absoluteMarkerPrefix.count))
        }
        if relativeDirectory.isEmpty {
            return root.standardizedFileURL.path
        }
        return root.appendingPathComponent(relativeDirectory).standardizedFileURL.path
    }

    /// Euristica per il default della root proposta nella sheet di export: la directory
    /// genitrice comune (standardizzata) di tutte le directory dei servizi del progetto.
    /// Nessun servizio, o nessun antenato comune sotto la home → `nil` (il chiamante ricade
    /// sulla home dell'utente).
    static func commonRoot(forServiceDirectories directories: [String]) -> URL? {
        let components = directories.compactMap { directory -> [String]? in
            let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
            let parts = standardized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return parts.isEmpty ? nil : parts
        }
        guard var common = components.first else { return nil }
        for parts in components.dropFirst() {
            var index = 0
            while index < common.count && index < parts.count && common[index] == parts[index] {
                index += 1
            }
            common = Array(common.prefix(index))
            if common.isEmpty { return nil }
        }
        guard !common.isEmpty else { return nil }
        return URL(fileURLWithPath: "/" + common.joined(separator: "/"))
    }
}
