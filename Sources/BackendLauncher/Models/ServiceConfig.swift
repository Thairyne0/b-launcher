import Foundation

/// Configurazione statica dei backend Skillera.
/// Per aggiungere/togliere un servizio o cambiare il path del progetto si edita SOLO questo file.
struct ServiceConfig: Identifiable, Hashable {
    let name: String          // nome breve (pm2-style)
    let directory: String     // sottodirectory dentro projectRoot
    let port: UInt16          // porta HTTP osservata per lo status
    var command: String = "npm run start:dev"

    var id: String { name }
    var displayName: String { "skill\(name)" }
    var workingDirectory: URL { ServiceConfig.projectRoot.appendingPathComponent(directory) }

    static let projectRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
    static let natsPort: UInt16 = 4222

    static let all: [ServiceConfig] = [
        ServiceConfig(name: "gateway", directory: "SKILLGATEWAY-BE", port: 4000),
        ServiceConfig(name: "id",      directory: "SKILLID-BE",      port: 4001),
        ServiceConfig(name: "atlas",   directory: "SKILLATLAS-BE",   port: 4003),
        ServiceConfig(name: "hr",      directory: "SKILLHR-BE",      port: 4006),
        ServiceConfig(name: "certet",  directory: "SKILLCERTET-BE",  port: 4010),
        ServiceConfig(name: "bill",    directory: "SKILLBILL-BE",    port: 4012),
    ]
}
