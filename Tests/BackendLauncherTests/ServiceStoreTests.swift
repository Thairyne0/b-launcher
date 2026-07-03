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
}
