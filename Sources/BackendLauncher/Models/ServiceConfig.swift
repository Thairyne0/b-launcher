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
    let directory: String     // sottodirectory dentro projectRoot
    let port: UInt16?         // porta HTTP osservata per lo status; nil = microservizio solo-NATS (readiness dai log)
    var command: String = "npm run start:dev"

    var id: String { name }
    var displayName: String { "skill\(name)" }
    var workingDirectory: URL { ServiceConfig.projectRoot.appendingPathComponent(directory) }

    static let projectRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
    static let natsPort: UInt16 = 4222

    static let all: [ServiceConfig] = [
        ServiceConfig(name: "gateway", directory: "SKILLGATEWAY-BE", port: 4000),
        ServiceConfig(name: "id",      directory: "SKILLID-BE",      port: 4001),
        ServiceConfig(name: "atlas",   directory: "SKILLATLAS-BE",   port: nil),
        ServiceConfig(name: "hr",      directory: "SKILLHR-BE",      port: nil),
        ServiceConfig(name: "certet",  directory: "SKILLCERTET-BE",  port: nil),
        ServiceConfig(name: "bill",    directory: "SKILLBILL-BE",    port: nil),
    ]

    static let profiles: [LaunchProfile] = [
        LaunchProfile(name: "Minimo (gateway + id)", serviceNames: ["gateway", "id"]),
        LaunchProfile(name: "Tutti", serviceNames: all.map(\.name)),
    ]
}
