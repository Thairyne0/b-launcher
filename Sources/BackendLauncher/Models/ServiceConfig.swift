import Foundation

/// Profili di avvio: sottoinsiemi di servizi avviabili in un click.
struct LaunchProfile: Identifiable, Hashable {
    let name: String
    let serviceNames: [String]
    var id: String { name }
}

/// Configurazione statica dei backend Skillera.
/// Per aggiungere/togliere un servizio o cambiare il path del progetto si edita SOLO questo file.
struct ServiceConfig: Identifiable, Hashable {
    let name: String          // nome breve (pm2-style)
    let directory: String     // sottodirectory dentro projectRoot (modalità legacy)
    let port: UInt16?         // porta HTTP osservata per lo status; nil = microservizio solo-NATS (readiness dai log)
    var command: String = "npm run start:dev"
    /// Path assoluto della working directory. Se valorizzato ha precedenza su `directory`
    /// (usato dal bridge `ServiceStore.serviceConfigs(for:)`). `nil` = modalità legacy relativa
    /// a `projectRoot`, invariata per compatibilità con i test esistenti.
    var absoluteDirectory: URL?

    var id: String { name }
    var displayName: String { "skill\(name)" }
    var workingDirectory: URL {
        absoluteDirectory ?? ServiceConfig.projectRoot.appendingPathComponent(directory)
    }

    static let projectRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
    static let natsPort: UInt16 = 4222

    static let legacyAll: [ServiceConfig] = [
        ServiceConfig(name: "gateway", directory: "SKILLGATEWAY-BE", port: 4000),
        ServiceConfig(name: "id",      directory: "SKILLID-BE",      port: 4001),
        ServiceConfig(name: "atlas",   directory: "SKILLATLAS-BE",   port: nil),
        ServiceConfig(name: "hr",      directory: "SKILLHR-BE",      port: nil),
        ServiceConfig(name: "certet",  directory: "SKILLCERTET-BE",  port: nil),
        ServiceConfig(name: "bill",    directory: "SKILLBILL-BE",    port: nil),
    ]

    /// Alias deprecato per compatibilità: preferire `legacyAll` (nome esplicito, dato che
    /// `ServiceStore` è ormai la fonte di verità sul progetto attivo).
    @available(*, deprecated, renamed: "legacyAll")
    static var all: [ServiceConfig] { legacyAll }

    static let legacyProfiles: [LaunchProfile] = [
        LaunchProfile(name: "Minimo (gateway + id)", serviceNames: ["gateway", "id"]),
        LaunchProfile(name: "Tutti", serviceNames: legacyAll.map(\.name)),
    ]

    /// ContentView legge ancora `ServiceConfig.profiles` direttamente (toolbar Menu):
    /// la migrazione a `model.profiles` è pianificata per la Fase C.
    static var profiles: [LaunchProfile] { legacyProfiles }
}
