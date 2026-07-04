import Foundation

/// Profili di avvio: sottoinsiemi di servizi avviabili in un click.
struct LaunchProfile: Identifiable, Hashable {
    let name: String
    let serviceNames: [String]
    var id: String { name }
}

/// Probe di prontezza di un servizio: come `ServiceController` decide che il processo è
/// "running" e non solo "starting". Generalizza la vecchia dicotomia porta/marker hardcoded.
enum ReadinessProbe: Hashable {
    case tcpPort(UInt16)
    case logMarker(String)
    case processAlive
    /// GET su `http://127.0.0.1:<port><path>` → 2xx = pronto (più preciso della sola porta
    /// TCP per backend che aprono il socket prima di essere davvero operativi).
    case httpHealth(port: UInt16, path: String)
}

/// Configurazione statica dei backend Skillera.
/// Per aggiungere/togliere un servizio o cambiare il path del progetto si edita SOLO questo file.
struct ServiceConfig: Identifiable, Hashable {
    let name: String          // nome breve (pm2-style)
    let directory: String     // sottodirectory dentro projectRoot (modalità legacy)
    let readiness: ReadinessProbe
    var command: String = "npm run start:dev"
    /// Path assoluto della working directory. Se valorizzato ha precedenza su `directory`
    /// (usato dal bridge `ServiceStore.serviceConfigs(for:)`). `nil` = modalità legacy relativa
    /// a `projectRoot`, invariata per compatibilità con i test esistenti.
    var absoluteDirectory: URL?
    /// Nome del progetto proprietario, per namespacing dell'id tra progetti diversi che
    /// possono avere servizi omonimi (es. due "gateway"). Default "" per compatibilità:
    /// tutti i test/init legacy che non lo valorizzano ottengono `id == name`, invariato.
    var projectName: String = ""
    /// Colore accento del progetto proprietario (hex, es. "#4F8EF7"), da `StoredProject`.
    /// Default `nil` in tutti gli init esistenti — nessuna rottura per i chiamanti storici.
    let accentColorHex: String?
    /// Nome SF Symbol da mostrare al posto dell'icona di default, da `StoredService`.
    /// Default `nil` in tutti gli init esistenti — nessuna rottura per i chiamanti storici.
    let symbolName: String?
    /// `true` = il backend dichiara di non usare `.env`: la UI non mostra badge/icona
    /// ".env mancante". Default `false` per tutti gli init esistenti.
    var envBadgeDisabled: Bool = false

    /// Namespaced su `projectName` quando presente ("Progetto/nome"), altrimenti il nome
    /// nudo — questo mantiene `id == name` per ogni config costruita senza `projectName`
    /// (tutti i path legacy/test esistenti).
    var id: String { projectName.isEmpty ? name : "\(projectName)/\(name)" }
    /// Nome mostrato in UI: esattamente il nome del servizio, senza trasformazioni.
    /// (Storicamente era "skill\(name)", retaggio dei backend SkillLocale hardcoded i cui
    /// nomi brevi erano "gateway"/"id"/…: con progetti/servizi creati dall'utente il prefisso
    /// produceva nomi sbagliati, es. "skillprova" per un servizio chiamato "prova".)
    var displayName: String { name }
    var workingDirectory: URL {
        absoluteDirectory ?? ServiceConfig.projectRoot.appendingPathComponent(directory)
    }

    /// Porta HTTP osservata per lo status, derivata da `readiness`; `nil` per marker/processAlive.
    /// Calcolata (non stored) per compatibilità con tutto il codice/test esistente che legge `.port`.
    var port: UInt16? {
        if case .tcpPort(let p) = readiness { return p }
        return nil
    }

    /// Init di compatibilità: firma storica `port:` usata da decine di test e da `legacyAll`.
    /// `port != nil` → `.tcpPort(port)`; `port == nil` → `.logMarker("successfully started")`
    /// (il marker hardcoded storico, invariato per i servizi solo-NATS legacy).
    init(name: String, directory: String, port: UInt16?,
         command: String = "npm run start:dev", absoluteDirectory: URL? = nil,
         projectName: String = "", accentColorHex: String? = nil, symbolName: String? = nil) {
        self.name = name
        self.directory = directory
        self.readiness = port.map { .tcpPort($0) } ?? .logMarker("successfully started")
        self.command = command
        self.absoluteDirectory = absoluteDirectory
        self.projectName = projectName
        self.accentColorHex = accentColorHex
        self.symbolName = symbolName
    }

    /// Init completo: readiness esplicita, per il bridge `ServiceStore` e i nuovi test.
    init(name: String, directory: String, command: String = "npm run start:dev",
         readiness: ReadinessProbe, absoluteDirectory: URL? = nil, projectName: String = "",
         accentColorHex: String? = nil, symbolName: String? = nil) {
        self.name = name
        self.directory = directory
        self.readiness = readiness
        self.command = command
        self.absoluteDirectory = absoluteDirectory
        self.projectName = projectName
        self.accentColorHex = accentColorHex
        self.symbolName = symbolName
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

    /// Alias legacy mantenuto solo per i test che verificano la configurazione statica
    /// storica: la UI (ContentView) legge `model.profiles` / `model.projectProfiles`,
    /// derivati dallo store, non più questo accessore.
    static var profiles: [LaunchProfile] { legacyProfiles }
}
