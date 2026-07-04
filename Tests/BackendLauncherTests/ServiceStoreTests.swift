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

    @Test func envBadgeDisabledPersistsAndBridgesToConfig() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)
        project.services.append(StoredService(
            name: "no-env", directory: "/tmp/no-env", command: "true",
            readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil),
            envBadgeDisabled: true))
        store.replaceProject(project)
        store.save()

        let reloaded = ServiceStore(fileURL: url)
        let reloadedProject = try #require(reloaded.projects.first)
        #expect(reloadedProject.services.last?.envBadgeDisabled == true)

        let configs = reloaded.serviceConfigs(for: reloadedProject)
        #expect(configs.last?.envBadgeDisabled == true)
        // Servizi senza il campo (file scritti da versioni precedenti): default false.
        #expect(configs.first?.envBadgeDisabled == false)
    }

    @Test func httpHealthBridgesToConfigAndBumpsStoreVersionTo2() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)
        project.services.append(StoredService(
            name: "healthy", directory: "/tmp/h", command: "true",
            readiness: StoredReadiness(kind: .httpHealth, port: 8080, marker: nil, path: "/health")))
        store.replaceProject(project)
        store.save()

        let config = try #require(store.serviceConfigs(for: store.projects[0]).last)
        #expect(config.readiness == .httpHealth(port: 8080, path: "/health"))

        // Il file scritto dichiara la versione minima che serve a leggerlo (2, feature
        // nuova presente) e si ricarica intatto.
        let decoded = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: url))
        #expect(decoded.version == 2)
        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects == store.projects)
    }

    @Test func storeWithoutHttpHealthKeepsVersion1ForDowngradeFriendliness() throws {
        let url = tempStoreURL()
        _ = ServiceStore(fileURL: url)
        let decoded = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: url))
        #expect(decoded.version == 1)
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

    // MARK: - renameProject

    @Test func renameProjectRenamesAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.renameProject(id: "Skillera", to: "Skillera2")

        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Skillera2")
        #expect(store.projects.contains { $0.name == "Skillera" } == false)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.name == "Skillera2")
    }

    @Test func renameProjectRejectsDuplicateCaseInsensitive() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.addProject(named: "Secondo")
        #expect(throws: StoreError.self) {
            try store.renameProject(id: "Secondo", to: "skillera")
        }
        #expect(store.projects.contains { $0.name == "Secondo" })
    }

    @Test func renameProjectThrowsWhenMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.renameProject(id: "non-esiste", to: "Nuovo")
        }
    }

    @Test func renameProjectRejectsEmptyName() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.renameProject(id: "Skillera", to: "   ")
        }
        #expect(store.projects.first?.name == "Skillera")
    }

    // MARK: - rebaseProject

    @Test func rebaseProjectRebasesDirsUnderCommonRoot() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        // Skillera migrato: tutti i servizi condividono la stessa root comune (projectRoot).
        let before = try #require(store.projects.first)
        let oldCommonRoot = try #require(ProjectTemplateCodec.commonRoot(
            forServiceDirectories: before.services.map(\.directory)))

        let newRoot = URL(fileURLWithPath: "/tmp/new-root-\(UUID().uuidString)")
        try store.rebaseProject(id: "Skillera", ontoRoot: newRoot)

        let after = try #require(store.projects.first)
        for (beforeService, afterService) in zip(before.services, after.services) {
            let standardizedOld = URL(fileURLWithPath: beforeService.directory).standardizedFileURL.path
            let suffix = String(standardizedOld.dropFirst(oldCommonRoot.path.count))
            let expected = newRoot.appendingPathComponent(suffix).standardizedFileURL.path
            #expect(afterService.directory == expected)
        }

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.services.first?.directory == after.services.first?.directory)
    }

    @Test func rebaseProjectLeavesDirOutsideCommonRootUnchanged() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)
        // Aggiungi un servizio con directory completamente fuori dalla root comune degli altri.
        project.services.append(StoredService(
            name: "outsider",
            directory: "/opt/elsewhere/outsider",
            command: "npm run start:dev",
            readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)
        ))
        store.replaceProject(project)
        store.save()

        let newRoot = URL(fileURLWithPath: "/tmp/new-root-\(UUID().uuidString)")
        try store.rebaseProject(id: "Skillera", ontoRoot: newRoot)

        let after = try #require(store.projects.first)
        let outsider = try #require(after.services.first { $0.name == "outsider" })
        #expect(outsider.directory == "/opt/elsewhere/outsider")
    }

    @Test func rebaseProjectThrowsWhenMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.rebaseProject(id: "non-esiste", ontoRoot: URL(fileURLWithPath: "/tmp"))
        }
    }

    // MARK: - updateInfraCheck

    @Test func updateInfraCheckSetsAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let newCheck = StoredInfraCheck(label: "Redis", port: 6379)
        try store.updateInfraCheck(projectID: "Skillera", infraCheck: newCheck)

        #expect(store.projects.first?.infraCheck == newCheck)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.infraCheck == newCheck)
    }

    @Test func updateInfraCheckRemovesWithNil() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.updateInfraCheck(projectID: "Skillera", infraCheck: nil)

        #expect(store.projects.first?.infraCheck == nil)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.infraCheck == nil)
    }

    @Test func updateInfraCheckThrowsWhenProjectMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.updateInfraCheck(projectID: "non-esiste", infraCheck: nil)
        }
    }

    // MARK: - updateProfiles

    @Test func updateProfilesSetsAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let newProfiles = [
            StoredProfile(name: "Solo gateway", serviceNames: ["gateway"]),
            StoredProfile(name: "Tutti", serviceNames: ["gateway", "atlas"]),
        ]
        try store.updateProfiles(projectID: "Skillera", profiles: newProfiles)

        #expect(store.projects.first?.profiles == newProfiles)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.profiles == newProfiles)
    }

    @Test func updateProfilesRejectsUnknownService() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let badProfiles = [StoredProfile(name: "Bad", serviceNames: ["nonexistent-service"])]
        #expect(throws: StoreError.self) {
            try store.updateProfiles(projectID: "Skillera", profiles: badProfiles)
        }
        // invariato
        #expect(store.projects.first?.profiles.contains { $0.name == "Bad" } == false)
    }

    @Test func updateProfilesRejectsDuplicateProfileNameCaseInsensitive() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let dupProfiles = [
            StoredProfile(name: "Tutti", serviceNames: ["gateway"]),
            StoredProfile(name: "tutti", serviceNames: ["atlas"]),
        ]
        #expect(throws: StoreError.self) {
            try store.updateProfiles(projectID: "Skillera", profiles: dupProfiles)
        }
    }

    @Test func updateProfilesThrowsWhenProjectMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.updateProfiles(projectID: "non-esiste", profiles: [])
        }
    }

    // MARK: - accentColorHex / symbolName (schema additivo, versione resta 1)

    @Test func accentColorHexAndSymbolNameRoundTripThroughSaveAndReload() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)
        project.accentColorHex = "#4F8EF7"
        project.services[0].symbolName = "bolt.fill"
        store.replaceProject(project)
        store.save()

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.accentColorHex == "#4F8EF7")
        #expect(reloaded.projects.first?.services.first?.symbolName == "bolt.fill")
    }

    @Test func oldV1JSONWithoutNewKeysDecodesFieldsAsNil() throws {
        // File scritto da una versione precedente dell'app: nessuna chiave accentColorHex/
        // symbolName presente. Deve decodificare senza errori con i nuovi campi a `nil`
        // (schema additivo, version resta 1 — nessuna migrazione necessaria).
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let oldJSON = """
        {
          "version": 1,
          "projects": [
            {
              "name": "Legacy",
              "services": [
                {
                  "name": "svc",
                  "directory": "/tmp/svc",
                  "command": "npm run start:dev",
                  "readiness": { "kind": "processAlive" }
                }
              ],
              "profiles": [],
              "infraCheck": null
            }
          ]
        }
        """
        try Data(oldJSON.utf8).write(to: url)

        let store = ServiceStore(fileURL: url)

        #expect(store.projects.count == 1)
        let project = try #require(store.projects.first)
        #expect(project.name == "Legacy")
        #expect(project.accentColorHex == nil)
        #expect(project.services.first?.symbolName == nil)

        // Non trattato come corrotto/futuro: nessun file .corrupt/.futureversion generato.
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("futureversion").path))
    }

    @Test func serviceConfigsBridgePopulatesAccentColorAndSymbolName() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        var project = try #require(store.projects.first)
        project.accentColorHex = "#FF0000"
        project.services[0].symbolName = "network"
        store.replaceProject(project)

        let configs = store.serviceConfigs(for: project)
        let gateway = try #require(configs.first { $0.name == project.services[0].name })
        #expect(gateway.accentColorHex == "#FF0000")
        #expect(gateway.symbolName == "network")

        // Un servizio senza symbolName esplicito riceve nil (default), non una stringa vuota.
        let other = try #require(configs.first { $0.name != project.services[0].name })
        #expect(other.symbolName == nil)
        #expect(other.accentColorHex == "#FF0000")  // stesso progetto, stesso colore accento
    }

    // MARK: - updateProjectAccentColor

    @Test func updateProjectAccentColorSetsAndPersists() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.updateProjectAccentColor(projectID: "Skillera", hex: "#4F8EF7")

        #expect(store.projects.first?.accentColorHex == "#4F8EF7")

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.accentColorHex == "#4F8EF7")
    }

    @Test func updateProjectAccentColorRemovesWithNil() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        try store.updateProjectAccentColor(projectID: "Skillera", hex: "#4F8EF7")
        try store.updateProjectAccentColor(projectID: "Skillera", hex: nil)

        #expect(store.projects.first?.accentColorHex == nil)

        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first?.accentColorHex == nil)
    }

    @Test func updateProjectAccentColorThrowsWhenProjectMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        #expect(throws: StoreError.self) {
            try store.updateProjectAccentColor(projectID: "non-esiste", hex: "#4F8EF7")
        }
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

    // MARK: - Template sync dal team

    /// Cartella temporanea univoca da usare come root "reale" di un progetto per i test di
    /// sync (che leggono davvero il file dal disco, a differenza degli altri test import/export
    /// che usano path fittizi mai letti).
    private func tempProjectRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func importTemplateWithSourceFileInsideRootSetsTemplateSync() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)

        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        let sync = try #require(imported.templateSync)
        #expect(sync.fileRelativePath == "skillera.blauncher.json")
        #expect(sync.lastImportedHash == TemplateSyncHasher.hash(data))
    }

    @Test func importTemplateWithSourceFileOutsideRootLeavesTemplateSyncNil() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        // File sorgente FUORI dalla root scelta per il progetto (es. scaricato in Downloads).
        let outsideFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-sync-outside-\(UUID().uuidString).json")
        try data.write(to: outsideFileURL)

        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: outsideFileURL)

        #expect(imported.templateSync == nil)
    }

    @Test func importTemplateWithoutSourceFileLeavesTemplateSyncNil() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let imported = try store.importTemplate(data, root: projectRoot)

        #expect(imported.templateSync == nil)
    }

    @Test func checkTemplateSyncReturnsNotTrackedWhenNoSyncInfo() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)

        #expect(store.checkTemplateSync(projectID: "Skillera") == .notTracked)
    }

    @Test func checkTemplateSyncReturnsNotTrackedWhenProjectMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)

        #expect(store.checkTemplateSync(projectID: "non-esiste") == .notTracked)
    }

    @Test func checkTemplateSyncReturnsUpToDateWhenHashMatches() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        #expect(store.checkTemplateSync(projectID: imported.id) == .upToDate)
    }

    @Test func checkTemplateSyncReturnsChangedWhenFileContentDiffers() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        // Simula un `git pull` che ha aggiornato il template: cambia il nome di un profilo.
        var template = try ProjectTemplateCodec.decode(data)
        template.profiles.append(StoredProfile(name: "Nuovo", serviceNames: []))
        let newData = try ProjectTemplateCodec.encode(template)
        try newData.write(to: templateFileURL)

        let status = store.checkTemplateSync(projectID: imported.id)
        #expect(status == .changed(newHash: TemplateSyncHasher.hash(newData)))
    }

    @Test func checkTemplateSyncReturnsFileMissingWhenFileDeleted() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        try FileManager.default.removeItem(at: templateFileURL)

        #expect(store.checkTemplateSync(projectID: imported.id) == .fileMissing)
    }

    @Test func syncProjectFromTemplateReplacesServicesKeepsNameAndColorUpdatesHash() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        // Personalizzazioni locali che devono sopravvivere alla sync.
        try store.updateProjectAccentColor(projectID: imported.id, hex: "#123456")

        // Il collega ha aggiunto un servizio al template e lo ha committato (git pull locale).
        var template = try ProjectTemplateCodec.decode(data)
        template.services.append(ProjectTemplate.TemplateService(
            name: "newsvc",
            relativeDirectory: "NEWSVC-BE",
            command: "npm run start:dev",
            readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)
        ))
        let newData = try ProjectTemplateCodec.encode(template)
        try newData.write(to: templateFileURL)

        try store.syncProjectFromTemplate(projectID: imported.id)

        let synced = try #require(store.projects.first { $0.id == imported.id })
        #expect(synced.name == "Skillera")
        #expect(synced.accentColorHex == "#123456")
        #expect(synced.services.contains { $0.name == "newsvc" })
        #expect(synced.services.count == template.services.count)
        #expect(synced.templateSync?.lastImportedHash == TemplateSyncHasher.hash(newData))

        // Persistito su disco.
        let reloaded = ServiceStore(fileURL: url)
        #expect(reloaded.projects.first { $0.id == imported.id }?.services.contains { $0.name == "newsvc" } == true)
    }

    @Test func syncProjectFromTemplateThrowsWhenNotTracked() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)

        #expect(throws: ServiceStore.TemplateSyncError.self) {
            try store.syncProjectFromTemplate(projectID: "Skillera")
        }
    }

    @Test func syncProjectFromTemplateThrowsWhenProjectMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)

        #expect(throws: StoreError.self) {
            try store.syncProjectFromTemplate(projectID: "non-esiste")
        }
    }

    @Test func syncProjectFromTemplateThrowsWhenFileMissing() throws {
        let url = tempStoreURL()
        let store = ServiceStore(fileURL: url)
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = try tempProjectRoot()
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        let imported = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)

        try FileManager.default.removeItem(at: templateFileURL)

        #expect(throws: ServiceStore.TemplateSyncError.self) {
            try store.syncProjectFromTemplate(projectID: imported.id)
        }
    }
}

@Suite struct TemplateSyncHasherTests {
    @Test func hashIsStableForSameData() {
        let data = Data("hello world".utf8)
        #expect(TemplateSyncHasher.hash(data) == TemplateSyncHasher.hash(data))
    }

    @Test func hashDiffersForDifferentData() {
        let a = Data("hello".utf8)
        let b = Data("world".utf8)
        #expect(TemplateSyncHasher.hash(a) != TemplateSyncHasher.hash(b))
    }

    @Test func hashIsLowercaseHex64Chars() {
        let hash = TemplateSyncHasher.hash(Data("test".utf8))
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(hash.allSatisfy { $0.isHexDigit })
    }
}
