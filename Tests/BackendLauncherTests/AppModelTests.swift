import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct AppModelTests {
    private var fakeConfigs: [ServiceConfig] {
        [
            ServiceConfig(name: "a", directory: "", port: 1, command: "sleep 60"),
            ServiceConfig(name: "b", directory: "", port: 2, command: "sleep 60"),
        ]
    }

    @Test func checkPortsSeesListener() async {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let results = await AppModel.checkPorts([listener.port, 1])
        #expect(results[listener.port] == true)
        #expect(results[1] == false)
    }

    @Test func startAllAndStopAll() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.startAll()
        let allUp = await waitUntil { model.services.allSatisfy { $0.processAlive } }
        #expect(allUp)
        #expect(model.anyRunning)
        model.stopAll()
        let allDown = await waitUntil { model.services.allSatisfy { !$0.processAlive } }
        #expect(allDown)
        #expect(!model.anyRunning)
    }

    @Test func startAllSkipsAlreadyRunning() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.services[0].start()
        _ = await waitUntil { model.services[0].processAlive }
        let firstPID = model.services[0].processID
        model.startAll()
        _ = await waitUntil { model.services[1].processAlive }
        #expect(model.services[0].processID == firstPID)  // non riavviato
        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func shutdownForQuitStopsEverything() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.startAll()
        _ = await waitUntil { model.anyRunning }
        await model.shutdownForQuit()
        #expect(!model.anyRunning)
    }

    @Test func startProfileStartsOnlyItsServices() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        let profile = LaunchProfile(name: "solo-a", serviceNames: ["a"])
        model.start(profile: profile)
        let aUp = await waitUntil { model.services[0].processAlive }
        #expect(aUp)
        #expect(!model.services[1].processAlive)
        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func profilesAreConfigured() {
        #expect(ServiceConfig.profiles.count == 2)
        #expect(ServiceConfig.profiles[0].serviceNames == ["gateway", "id"])
        #expect(ServiceConfig.profiles[1].serviceNames == ServiceConfig.all.map(\.name))
    }

    @Test func toggleAllTerminalsFlipsBetweenAllAndNone() {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        #expect(model.expandedServices.isEmpty)
        model.toggleAllTerminals()
        #expect(model.expandedServices.count == model.services.count)
        model.toggleAllTerminals()
        #expect(model.expandedServices.isEmpty)
    }

    @Test func toggleTerminalTogglesSingle() {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        let id = model.services[0].id
        model.toggleTerminal(id)
        #expect(model.expandedServices.contains(id))
        model.toggleTerminal(id)
        #expect(!model.expandedServices.contains(id))
    }

    @Test func revealServiceExpandsAndFiltersErrors() {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.revealService(named: "a")
        #expect(model.expandedServices.contains("a"))
        #expect(model.services[0].logs.levelFilter == .errors)
        #expect(model.revealRequestCount == 1)
        #expect(model.lastRevealedServiceID == "a")

        model.revealService(named: "does-not-exist")
        #expect(model.revealRequestCount == 1)  // invariato: nessun crash, nessuna modifica
        #expect(model.lastRevealedServiceID == "a")  // invariato
    }

    // MARK: - Multi-progetto + reloadFromStore (Phase D)

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-appmodel-tests-\(UUID().uuidString)")
            .appendingPathComponent("services.json")
    }

    /// Store con due progetti fittizi, comandi "sleep" innocui, nessuna migrazione Skillera
    /// coinvolta (progetti costruiti da zero via addProject/addService).
    private func makeTwoProjectStore() throws -> ServiceStore {
        let store = ServiceStore(fileURL: tempStoreURL())
        // Rimuovi il progetto Skillera migrato di default: i test qui vogliono un fixture pulito.
        store.removeProject(id: "Skillera")
        try store.addProject(named: "ProjA")
        try store.addProject(named: "ProjB")
        try store.addService(
            StoredService(name: "svc", directory: "/tmp", command: "sleep 60",
                         readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)),
            toProject: "ProjA"
        )
        try store.addService(
            StoredService(name: "svc", directory: "/tmp", command: "sleep 60",
                         readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)),
            toProject: "ProjB"
        )
        return store
    }

    @Test func namespacedIdsDistinctAcrossProjects() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        #expect(model.services.count == 2)
        let ids = Set(model.services.map(\.id))
        #expect(ids == ["ProjA/svc", "ProjB/svc"])
    }

    @Test func legacyConfigWithEmptyProjectNameKeepsIDEqualToName() {
        let config = ServiceConfig(name: "gateway", directory: "", port: 4000)
        #expect(config.projectName == "")
        #expect(config.id == "gateway")
    }

    @Test func reloadAddsNewService() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        #expect(model.services.count == 2)

        try store.addService(
            StoredService(name: "extra", directory: "/tmp", command: "sleep 60",
                         readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)),
            toProject: "ProjA"
        )
        model.reloadFromStore()
        #expect(model.services.count == 3)
        #expect(model.services.contains { $0.id == "ProjA/extra" })
    }

    @Test func reloadRemovesNonRunningService() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        store.removeService(named: "svc", fromProject: "ProjA")
        model.reloadFromStore()
        #expect(model.services.count == 1)
        #expect(model.services.first?.id == "ProjB/svc")
    }

    @Test func reloadKeepsSameInstanceForUnchangedConfig() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let before = model.services.first { $0.id == "ProjA/svc" }
        model.reloadFromStore()  // nessuna mutazione: la config è identica
        let after = model.services.first { $0.id == "ProjA/svc" }
        #expect(before != nil && after != nil)
        #expect(before === after)
    }

    @Test func reloadSurvivesRunningServiceUntouched() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let running = try #require(model.services.first { $0.id == "ProjA/svc" })
        running.start()
        _ = await waitUntil { running.processAlive }
        let objectIDBefore = ObjectIdentifier(running)

        // Modifica la config del servizio in esecuzione: il controller vivo non va sostituito.
        var project = store.projects.first { $0.name == "ProjA" }!
        project.services[0].command = "sleep 120"
        store.replaceProject(project)
        store.save()
        model.reloadFromStore()

        let after = try #require(model.services.first { $0.id == "ProjA/svc" })
        #expect(ObjectIdentifier(after) == objectIDBefore)
        #expect(after.processAlive)
        #expect(model.pendingConfigChanges.contains("ProjA/svc"))

        after.stop()
        _ = await waitUntil { !after.processAlive }
    }

    @Test func reloadRemovedWhileRunningStopsProcess() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let running = try #require(model.services.first { $0.id == "ProjA/svc" })
        running.start()
        _ = await waitUntil { running.processAlive }

        store.removeService(named: "svc", fromProject: "ProjA")
        model.reloadFromStore()

        #expect(!model.services.contains { $0.id == "ProjA/svc" })
        let eventuallyDead = await waitUntil { !running.processAlive }
        #expect(eventuallyDead)
    }

    @Test func reloadPrunesExpandedServices() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        model.toggleTerminal("ProjA/svc")
        #expect(model.expandedServices.contains("ProjA/svc"))

        store.removeService(named: "svc", fromProject: "ProjA")
        model.reloadFromStore()
        #expect(!model.expandedServices.contains("ProjA/svc"))
    }
}
