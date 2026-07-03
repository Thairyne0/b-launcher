import Foundation
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct ServiceStoreTests {
    /// URL temporaneo univoco per test, mai la vera Application Support.
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-store-tests-\(UUID().uuidString)")
            .appendingPathComponent("services.json")
    }

    @Test func migrationCreatesSkilleraWithSixServices() throws {
        let url = tempStoreURL()
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let store = ServiceStore(fileURL: url)

        #expect(store.projects.count == 1)
        let project = try #require(store.projects.first)
        #expect(project.name == "Skillera")
        #expect(project.services.count == 6)

        let portReadinessCount = project.services.filter { $0.readiness.kind == .port }.count
        let markerReadinessCount = project.services.filter { $0.readiness.kind == .logMarker }.count
        #expect(portReadinessCount == 2)
        #expect(markerReadinessCount == 4)

        #expect(project.profiles.map(\.name) == ["Minimo (gateway + id)", "Tutti"])
        #expect(project.infraCheck?.label == "NATS")
        #expect(project.infraCheck?.port == 4222)

        // Il file deve essere stato scritto su disco dopo la migrazione.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func roundTripPersistence() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)

        let extra = StoredService(
            name: "extra",
            directory: "/tmp/extra",
            command: "npm run start:dev",
            readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)
        )
        project.services.append(extra)
        store.replaceProject(project)
        store.save()

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects == store.projects)
        #expect(reloaded.projects.first?.services.count == 7)
        #expect(reloaded.projects.first?.services.last?.name == "extra")
    }

    @Test func futureVersionFileIsPreservedNotOverwritten() throws {
        // File scritto da una versione futura dell'app (es. v2 con schema incompatibile):
        // non va trattato come v1 né sovrascritto — va messo da parte per non perdere dati
        // se l'utente fa downgrade.
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let futureProject = StoredProject(
            name: "FutureProject",
            services: [],
            profiles: [],
            infraCheck: nil
        )
        let futureFile = StoreFile(version: 99, projects: [futureProject])
        let data = try JSONEncoder().encode(futureFile)
        try data.write(to: url)

        let store = ServiceStore(fileURL: url)

        let futureVersionURL = url.appendingPathExtension("futureversion")
        #expect(FileManager.default.fileExists(atPath: futureVersionURL.path))
        let preserved = try Data(contentsOf: futureVersionURL)
        #expect(preserved == data)

        // Lo store corrente ricade sulla migrazione, non sul contenuto v99.
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Skillera")
    }

    @Test func futureVersionPreservationFailureSkipsSaveAndKeepsOriginalIntact() throws {
        // Se il backup del file di versione futura FALLISCE, lo store non deve scrivere su
        // disco in questa sessione: altrimenti sovrascriveremmo silenziosamente l'unica copia
        // dei dati "futuri" dell'utente con la migrazione v1.
        //
        // init() fa PRIMA un `try? removeItem(at: futureVersionURL)` (no-op cleanup) e SOLO
        // DOPO il `moveItem`: un `.futureversion` pre-creato verrebbe quindi ripulito da quel
        // removeItem prima che il move possa fallire per collisione — non basta come fixture.
        // chmod della DIRECTORY contenitore a sola lettura/esecuzione (0o555, niente write)
        // blocca invece SIA la removeItem che la moveItem (nessuna delle due può modificare
        // le entry della directory), rendendo il fallimento deterministico indipendentemente
        // dall'ordine delle operazioni in init().
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("services.json")

        let futureProject = StoredProject(name: "FutureProject", services: [], profiles: [], infraCheck: nil)
        let futureFile = StoreFile(version: 99, projects: [futureProject])
        let originalData = try JSONEncoder().encode(futureFile)
        try originalData.write(to: url)

        let futureVersionURL = url.appendingPathExtension("futureversion")
        try Data("versione-futura-precedente".utf8).write(to: futureVersionURL)

        chmod(dir.path, 0o555)
        defer {
            chmod(dir.path, 0o755)  // ripristina per permettere la pulizia del tmp dir
            try? FileManager.default.removeItem(at: dir)
        }

        let store = ServiceStore(fileURL: url)

        // In memoria per questa sessione, ricade comunque sulla migrazione (comportamento
        // in-process invariato: l'utente può continuare a usare l'app).
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Skillera")

        // MA il file originale su disco non deve essere stato toccato: niente save().
        let onDiskAfter = try Data(contentsOf: url)
        #expect(onDiskAfter == originalData)
    }

    @Test func corruptFileFallsBackToMigration() throws {
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("not valid json { { {".utf8).write(to: url)

        let store = ServiceStore(fileURL: url)

        let corruptURL = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Skillera")
    }

    @Test func serviceConfigsBridge() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let project = try #require(store.projects.first)

        let configs = store.serviceConfigs(for: project)
        #expect(configs.count == 6)

        let gateway = try #require(configs.first { $0.name == "gateway" })
        #expect(gateway.port == 4000)

        let atlas = try #require(configs.first { $0.name == "atlas" })
        #expect(atlas.port == nil)
        #expect(atlas.workingDirectory.path.hasSuffix("SKILLATLAS-BE"))
        #expect(atlas.workingDirectory.isFileURL)
        #expect(atlas.command == "npm run start:dev")
        #expect(atlas.workingDirectory.path.hasPrefix("/"))
    }

    @Test func bridgePreservesCustomLogMarkerString() throws {
        // Il marker persistito su disco deve sopravvivere al bridge invariato, non essere
        // forzato all'hardcoded "successfully started".
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)

        let custom = StoredService(
            name: "custom",
            directory: "/tmp/custom",
            command: "npm run start:dev",
            readiness: StoredReadiness(kind: .logMarker, port: nil, marker: "custom-marker")
        )
        project.services.append(custom)
        store.replaceProject(project)

        let configs = store.serviceConfigs(for: project)
        let customConfig = try #require(configs.first { $0.name == "custom" })
        #expect(customConfig.readiness == .logMarker("custom-marker"))
    }

    @Test func serviceConfigsBridgeSetsProjectNameForNamespacing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let project = try #require(store.projects.first)

        let configs = store.serviceConfigs(for: project)
        let gateway = try #require(configs.first { $0.name == "gateway" })
        #expect(gateway.projectName == "Skillera")
        #expect(gateway.id == "Skillera/gateway")
    }

    // MARK: - Mutazioni (Phase D)

    @Test func addProjectAppendsAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.addProject(named: "NuovoProgetto")

        #expect(store.projects.count == 2)
        #expect(store.projects.last?.name == "NuovoProgetto")
        #expect(store.projects.last?.services.isEmpty == true)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.count == 2)
        #expect(reloaded.projects.last?.name == "NuovoProgetto")
    }

    @Test func addProjectTrimsWhitespace() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.addProject(named: "  Spazi  ")
        #expect(store.projects.last?.name == "Spazi")
    }

    @Test func addProjectRejectsEmptyName() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.addProject(named: "   ")
        }
        #expect(store.projects.count == 1)
    }

    @Test func addProjectRejectsCaseInsensitiveDuplicate() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.addProject(named: "skillera")
        }
        #expect(store.projects.count == 1)
    }

    @Test func removeProjectDeletesAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.addProject(named: "Secondo")
        store.removeProject(id: "Skillera")

        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Secondo")

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.projects.first?.name == "Secondo")
    }

    @Test func removeProjectNotFoundIsNoOp() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        store.removeProject(id: "non-esiste")
        #expect(store.projects.count == 1)
    }

    @Test func addServiceAppendsAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let service = StoredService(name: "newsvc", directory: "/tmp/newsvc",
                                    command: "npm run start:dev",
                                    readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil))
        try store.addService(service, toProject: "Skillera")

        #expect(store.projects.first?.services.count == 7)
        #expect(store.projects.first?.services.last?.name == "newsvc")

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.services.count == 7)
    }

    @Test func addServiceRejectsCaseInsensitiveDuplicateWithinProject() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let service = StoredService(name: "GATEWAY", directory: "/tmp/x", command: "npm run start:dev",
                                    readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil))
        #expect(throws: StoreError.self) {
            try store.addService(service, toProject: "Skillera")
        }
        #expect(store.projects.first?.services.count == 6)
    }

    @Test func addServiceThrowsWhenProjectNotFound() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let service = StoredService(name: "x", directory: "/tmp/x", command: "npm run start:dev",
                                    readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil))
        #expect(throws: StoreError.self) {
            try store.addService(service, toProject: "non-esiste")
        }
    }

    @Test func updateServiceRenamesSuccessfully() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let original = try #require(store.projects.first?.services.first { $0.name == "atlas" })
        var renamed = original
        renamed.name = "atlas2"
        try store.updateService(named: "atlas", inProject: "Skillera", with: renamed)

        #expect(store.projects.first?.services.contains { $0.name == "atlas2" } == true)
        #expect(store.projects.first?.services.contains { $0.name == "atlas" } == false)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.services.contains { $0.name == "atlas2" } == true)
    }

    @Test func updateServiceRenameCollisionRejected() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let original = try #require(store.projects.first?.services.first { $0.name == "atlas" })
        var renamed = original
        renamed.name = "gateway"  // collide con un servizio esistente
        #expect(throws: StoreError.self) {
            try store.updateService(named: "atlas", inProject: "Skillera", with: renamed)
        }
        // invariato
        #expect(store.projects.first?.services.contains { $0.name == "atlas" } == true)
    }

    @Test func updateServiceKeepingSameNameSucceeds() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let original = try #require(store.projects.first?.services.first { $0.name == "atlas" })
        var updated = original
        updated.command = "npm run start:prod"
        try store.updateService(named: "atlas", inProject: "Skillera", with: updated)
        #expect(store.projects.first?.services.first { $0.name == "atlas" }?.command == "npm run start:prod")
    }

    @Test func removeServiceDeletesAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        store.removeService(named: "atlas", fromProject: "Skillera")

        #expect(store.projects.first?.services.count == 5)
        #expect(store.projects.first?.services.contains { $0.name == "atlas" } == false)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.services.count == 5)
    }

    @Test func removeServiceNotFoundIsNoOp() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        store.removeService(named: "non-esiste", fromProject: "Skillera")
        #expect(store.projects.first?.services.count == 6)
    }

    // MARK: - Template export/import (Phase E)

    @Test func exportUnknownProjectThrows() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.exportTemplate(projectID: "non-esiste", root: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func exportTemplateProducesDecodableData() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let root = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")

        let data = try store.exportTemplate(projectID: "Skillera", root: root)
        let template = try ProjectTemplateCodec.decode(data)

        #expect(template.name == "Skillera")
        #expect(template.services.count == 6)
        #expect(template.services.allSatisfy { !$0.relativeDirectory.hasPrefix("/") })
    }

    @Test func importTemplatePersistsAndReloadSeesProject() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)

        // Rimuovi il progetto originale per evitare collisione di nome sull'import.
        store.removeProject(id: "Skillera")

        let importRoot = URL(fileURLWithPath: "/Users/colleague/repos/SkillLocale")
        let imported = try store.importTemplate(data, root: importRoot)

        #expect(imported.name == "Skillera")
        #expect(store.projects.contains { $0.name == "Skillera" })
        let gateway = try #require(store.projects.first { $0.name == "Skillera" }?.services.first { $0.name == "gateway" })
        #expect(gateway.directory == "/Users/colleague/repos/SkillLocale/SKILLGATEWAY-BE")

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.contains { $0.name == "Skillera" })
    }

    @Test func importCollisionThrowsDuplicate() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)

        // Store ha già "Skillera" (dalla migrazione): l'import senza override collide.
        #expect(throws: StoreError.self) {
            try store.importTemplate(data, root: URL(fileURLWithPath: "/Users/colleague/repos/SkillLocale"))
        }
        #expect(store.projects.count == 1)
    }

    @Test func importWithOverrideNameSucceeds() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)

        let imported = try store.importTemplate(data, root: URL(fileURLWithPath: "/Users/colleague/repos/SkillLocale"),
                                                  nameOverride: "Skillera (colleague)")

        #expect(imported.name == "Skillera (colleague)")
        #expect(store.projects.count == 2)
        #expect(store.projects.contains { $0.name == "Skillera (colleague)" })
    }
}
