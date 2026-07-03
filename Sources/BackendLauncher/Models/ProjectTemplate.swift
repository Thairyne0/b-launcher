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
    }
}

/// Errori di decodifica/encoding del template.
enum ProjectTemplateError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Questo template è stato creato da una versione più recente dell'app (versione \(version)): aggiorna Backend Launcher per importarlo."
        }
    }
}

/// Funzioni pure di conversione `StoredProject` <-> `ProjectTemplate` e (de)serializzazione JSON.
/// Nessuno stato — completamente testabile senza `ServiceStore`.
enum ProjectTemplateCodec {
    /// Marker-prefisso usato quando la directory di un servizio non ricade sotto `root`:
    /// preserviamo il path assoluto invece di produrre un relativo insensato (es. "../../../x").
    static let absoluteMarkerPrefix = "abs:"

    private static let currentVersion = 1

    /// Export: calcola i path relativi rispetto a `root`. Servizi FUORI da root → path
    /// assoluto preservato con prefisso marker "abs:" (fallback esplicito, documentato).
    static func makeTemplate(from project: StoredProject, root: URL) -> ProjectTemplate {
        let standardizedRoot = root.standardizedFileURL.path
        let services = project.services.map { service -> ProjectTemplate.TemplateService in
            ProjectTemplate.TemplateService(
                name: service.name,
                relativeDirectory: relativePath(forServiceDirectory: service.directory, root: standardizedRoot),
                command: service.command,
                readiness: service.readiness
            )
        }
        return ProjectTemplate(
            templateVersion: currentVersion,
            name: project.name,
            services: services,
            profiles: project.profiles,
            infraCheck: project.infraCheck
        )
    }

    /// Import: ricostruisce `StoredProject` risolvendo i relativi su `root`; le entry
    /// "abs:"-prefixed vengono usate as-is (assolute). Il nome del progetto può essere
    /// sovrascritto (utile in caso di collisione col nome esistente).
    static func makeProject(from template: ProjectTemplate, root: URL, nameOverride: String?) -> StoredProject {
        let standardizedRoot = root.standardizedFileURL
        let services = template.services.map { templateService -> StoredService in
            StoredService(
                name: templateService.name,
                directory: resolvedDirectory(relativeDirectory: templateService.relativeDirectory, root: standardizedRoot),
                command: templateService.command,
                readiness: templateService.readiness
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
