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

    @Test func checkHealthEndpointsDistinguishes200From500AndClosedPort() async {
        let ok = makeHTTPResponder(status: 200)
        defer { close(ok.fd) }
        let broken = makeHTTPResponder(status: 500)
        defer { close(broken.fd) }

        let okEndpoint = AppModel.HealthEndpoint(port: ok.port, path: "/health")
        let brokenEndpoint = AppModel.HealthEndpoint(port: broken.port, path: "/health")
        let closedEndpoint = AppModel.HealthEndpoint(port: 1, path: "/health")

        let results = await AppModel.checkHealthEndpoints([okEndpoint, brokenEndpoint, closedEndpoint])

        #expect(results[okEndpoint]?.ok == true)
        #expect(results[brokenEndpoint]?.ok == false)
        #expect(results[closedEndpoint]?.ok == false)
        // Latenza misurata quando c'è una risposta HTTP (anche non-2xx), assente se la
        // connessione fallisce del tutto.
        #expect(results[okEndpoint]?.latencyMs != nil)
        #expect(results[brokenEndpoint]?.latencyMs != nil)
        #expect(results[closedEndpoint]?.latencyMs == nil)
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

    /// Store con due progetti fittizi, comandi "sleep" innocui (un'installazione nuova
    /// parte vuota, quindi i progetti si costruiscono da zero via addProject/addService).
    private func makeTwoProjectStore() throws -> ServiceStore {
        let store = ServiceStore(fileURL: tempStoreURL())
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

    @Test func startProjectRespectsStartAfterOrder() async throws {
        // "primo" diventa running quando stampa il marker; "secondo" dipende da lui:
        // quando "secondo" risulta vivo, "primo" DEVE già essere running.
        let store = ServiceStore(fileURL: tempStoreURL())
        try store.addProject(named: "P")
        try store.addService(
            StoredService(name: "primo", directory: "/tmp", command: "echo pronto-adesso && sleep 60",
                          readiness: StoredReadiness(kind: .logMarker, port: nil, marker: "pronto-adesso")),
            toProject: "P")
        try store.addService(
            StoredService(name: "secondo", directory: "/tmp", command: "sleep 60",
                          readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil),
                          startAfter: ["primo"]),
            toProject: "P")
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let primo = try #require(model.services.first { $0.config.name == "primo" })
        let secondo = try #require(model.services.first { $0.config.name == "secondo" })

        model.startProject(named: "P")

        let secondoAlive = await waitUntil { secondo.processAlive }
        #expect(secondoAlive)
        // L'orchestratore ha aspettato la readiness di "primo" prima di avviare "secondo".
        #expect(primo.status == .running)

        model.stopAll()
        _ = await waitUntil { model.services.allSatisfy { !$0.processAlive } }
    }

    @Test func dependencyCycleFallsBackToFlatStart() async throws {
        let store = ServiceStore(fileURL: tempStoreURL())
        try store.addProject(named: "P")
        try store.addService(
            StoredService(name: "a", directory: "/tmp", command: "sleep 60",
                          readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil),
                          startAfter: ["b"]),
            toProject: "P")
        try store.addService(
            StoredService(name: "b", directory: "/tmp", command: "sleep 60",
                          readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil),
                          startAfter: ["a"]),
            toProject: "P")
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)

        model.startProject(named: "P")

        // Ciclo: nessun deadlock, partono comunque entrambi (avvio piatto + avviso nei log).
        let allAlive = await waitUntil { model.services.allSatisfy { $0.processAlive } }
        #expect(allAlive)
        #expect(model.services.allSatisfy { c in
            c.logs.lines.contains { $0.text.contains("dipendenze circolari") }
        })

        model.stopAll()
        _ = await waitUntil { model.services.allSatisfy { !$0.processAlive } }
    }

    @Test func globalErrorsAggregatesAcrossServicesSortedByTime() {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.services[0].logs.ingest("riga normale\n10:00:01 ERROR boom-a\n")
        model.services[1].logs.ingest("10:00:02 ERROR boom-b\n")

        let errors = model.globalErrors

        #expect(errors.count == 2)
        #expect(Set(errors.map(\.serviceName)) == ["a", "b"])
        #expect(errors.allSatisfy { $0.line.text.contains("boom") })
        // Ordinati dal più recente al più vecchio.
        #expect(zip(errors, errors.dropFirst()).allSatisfy { $0.line.receivedAt >= $1.line.receivedAt })
    }

    @Test func recoveryNoticeEmittedWhenCrashedServiceComesBack() async throws {
        // Comando condizionato da un file-flag: prima run crasha (exit 9), dopo la
        // "riparazione" (file creato) resta vivo → running (readiness processAlive).
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: flag) }
        let config = ServiceConfig(name: "flaky", directory: "",
                                   command: "[ -f '\(flag.path)' ] && sleep 60 || exit 9",
                                   readiness: .processAlive)
        let model = AppModel(configs: [config], cwd: "/tmp", pollingEnabled: false,
                             crashNotificationsEnabled: false)
        let service = try #require(model.services.first)

        service.start()
        _ = await waitUntil { service.status == .crashed(exitCode: 9) }
        #expect(service.awaitingRecoveryNotice)
        #expect(model.emitRecoveryNotices().isEmpty)  // non ancora running: niente notifica

        try Data().write(to: flag)  // "riparato"
        service.start()
        _ = await waitUntil { service.status == .running }

        #expect(model.emitRecoveryNotices() == [service.id])
        #expect(service.awaitingRecoveryNotice == false)
        #expect(model.emitRecoveryNotices().isEmpty)  // una volta sola

        service.stop()
        _ = await waitUntil { !service.processAlive }
    }

    @Test func manualStopDisarmsRecoveryNotice() async throws {
        let config = ServiceConfig(name: "crasher", directory: "", command: "sleep 60",
                                   readiness: .processAlive)
        let model = AppModel(configs: [config], cwd: "/tmp", pollingEnabled: false,
                             crashNotificationsEnabled: false)
        let service = try #require(model.services.first)
        service.start()
        _ = await waitUntil { service.processAlive }
        // Uccisione esterna = crash vero → flag armato.
        if let pid = service.processID { kill(pid, SIGKILL) }
        _ = await waitUntil { !service.processAlive }
        #expect(service.awaitingRecoveryNotice)

        service.start()
        _ = await waitUntil { service.processAlive }
        service.stop()  // stop manuale PRIMA che scatti la notifica: disarma
        _ = await waitUntil { !service.processAlive }
        #expect(service.awaitingRecoveryNotice == false)
        #expect(model.emitRecoveryNotices().isEmpty)
    }

    @Test func globalErrorGroupsCollapseIdenticalErrorsPerService() {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.services[0].logs.ingest("""
        10:00 ERROR connessione rifiutata
        10:01 ERROR connessione rifiutata
        10:02 ERROR altro problema
        10:03 ERROR connessione rifiutata
        """ + "\n")
        // Stesso testo su un ALTRO servizio: gruppo separato (il servizio conta).
        model.services[1].logs.ingest("10:04 ERROR connessione rifiutata\n")

        let groups = model.globalErrorGroups

        #expect(groups.count == 3)
        let ripetuto = groups.first { $0.serviceName == "a" && $0.text.contains("rifiutata") }
        #expect(ripetuto?.count == 3)
        let singolo = groups.first { $0.serviceName == "a" && $0.text.contains("altro") }
        #expect(singolo?.count == 1)
        #expect(groups.first { $0.serviceName == "b" }?.count == 1)
        // Ordinati per occorrenza più recente.
        #expect(zip(groups, groups.dropFirst()).allSatisfy { $0.lastReceivedAt >= $1.lastReceivedAt })
    }

    @Test func infraStatusTrackedPerProject() async throws {
        // Due progetti con spie infra su porte diverse: una in ascolto, l'altra no.
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let store = ServiceStore(fileURL: tempStoreURL())
        try store.addProject(named: "Su")
        try store.addProject(named: "Giu")
        try store.updateInfraCheck(projectID: "Su",
                                   infraCheck: StoredInfraCheck(label: "Redis", port: listener.port))
        try store.updateInfraCheck(projectID: "Giu",
                                   infraCheck: StoredInfraCheck(label: "NATS", port: 1))

        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        await model.refreshInfraStatus()

        #expect(model.infraUp["Su"] == true)
        #expect(model.infraUp["Giu"] == false)
        // Compatibilità storica: natsUp riflette il PRIMO progetto con spia configurata.
        #expect(model.natsUp == true)
    }

    @Test func startProjectWarnsOnlyWhenItsOwnInfraIsDown() async throws {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let store = ServiceStore(fileURL: tempStoreURL())
        try store.addProject(named: "Su")
        try store.addProject(named: "Giu")
        try store.updateInfraCheck(projectID: "Su",
                                   infraCheck: StoredInfraCheck(label: "Redis", port: listener.port))
        try store.updateInfraCheck(projectID: "Giu",
                                   infraCheck: StoredInfraCheck(label: "NATS", port: 1))
        try store.addService(
            StoredService(name: "svc", directory: "/tmp", command: "sleep 60",
                          readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)),
            toProject: "Su")
        try store.addService(
            StoredService(name: "svc", directory: "/tmp", command: "sleep 60",
                          readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)),
            toProject: "Giu")

        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        await model.refreshInfraStatus()

        model.startProject(named: "Su")   // infra su: nessun warning
        #expect(model.showNATSWarning == false)
        model.startProject(named: "Giu")  // infra giù: warning col check del progetto
        #expect(model.showNATSWarning == true)
        #expect(model.warningInfraCheck?.label == "NATS")
        model.stopAll()
        _ = await waitUntil { model.services.allSatisfy { !$0.processAlive } }
    }

    @Test func servicesByProjectGroupsPreservingOrder() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)

        let grouped = model.servicesByProject
        #expect(grouped.map(\.projectName) == ["ProjA", "ProjB"])
        #expect(grouped.allSatisfy { $0.services.count == 1 })
        #expect(grouped[0].services[0].id == "ProjA/svc")
    }

    @Test func servicesByProjectHandlesLegacyEmptyProjectName() {
        // Init legacy (nessuno store): tutti i servizi hanno projectName "" → un solo gruppo.
        let model = AppModel(configs: [
            ServiceConfig(name: "a", directory: "", port: 1),
            ServiceConfig(name: "b", directory: "", port: 2),
        ], pollingEnabled: false, crashNotificationsEnabled: false)

        let grouped = model.servicesByProject
        #expect(grouped.count == 1)
        #expect(grouped[0].projectName == "")
        #expect(grouped[0].services.count == 2)
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

    @Test func pollAppliesPendingConfigWhenServiceStops() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: true, crashNotificationsEnabled: false)
        let running = try #require(model.services.first { $0.id == "ProjA/svc" })
        running.start()
        _ = await waitUntil { running.processAlive }

        var project = store.projects.first { $0.name == "ProjA" }!
        project.services[0].command = "sleep 120"
        store.replaceProject(project)
        store.save()
        model.reloadFromStore()
        #expect(model.pendingConfigChanges.contains("ProjA/svc"))

        running.stop()
        // Il poll (tick da 2s) deve applicare la modifica e togliere il pending DA SOLO.
        let applied = await waitUntil(timeout: 12) {
            model.pendingConfigChanges.isEmpty
                && model.services.first { $0.id == "ProjA/svc" }?.config.command == "sleep 120"
        }
        #expect(applied)
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

    @Test func startProjectStartsOnlyThatProjectsServices() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        model.startProject(named: "ProjA")

        let aUp = await waitUntil { model.services.first { $0.id == "ProjA/svc" }?.processAlive == true }
        #expect(aUp)
        #expect(model.services.first { $0.id == "ProjB/svc" }?.processAlive == false)

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func startProjectSkipsAlreadyRunningServices() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let running = try #require(model.services.first { $0.id == "ProjA/svc" })
        running.start()
        _ = await waitUntil { running.processAlive }
        let firstPID = running.processID

        model.startProject(named: "ProjA")
        // Non deve essere riavviato (stesso PID).
        #expect(running.processID == firstPID)

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func stopProjectStopsOnlyThatProjectsServices() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        model.startAll()
        _ = await waitUntil { model.services.allSatisfy { $0.processAlive } }

        model.stopProject(named: "ProjA")
        let aDown = await waitUntil { model.services.first { $0.id == "ProjA/svc" }?.processAlive == false }
        #expect(aDown)
        #expect(model.services.first { $0.id == "ProjB/svc" }?.processAlive == true)

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func renameProjectViaStoreStopsRunningServiceOnReload() async throws {
        // Documenta ed esercita la semantica ATTESA (non una sorpresa): renameProject cambia
        // StoredProject.id (== name), quindi gli id namespaced dei suoi servizi cambiano
        // ("ProjA/svc" -> "ProjANovo/svc"). Per reloadFromStore() questo è indistinguibile da
        // "rimuovi il vecchio id, aggiungi il nuovo": un servizio in esecuzione al momento del
        // rename viene FERMATO silenziosamente al reload, esattamente come un update di
        // rinomina servizio. Comportamento accettato e documentato, testato qui esplicitamente.
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let running = try #require(model.services.first { $0.id == "ProjA/svc" })
        running.start()
        _ = await waitUntil { running.processAlive }

        try store.renameProject(id: "ProjA", to: "ProjANovo")
        model.reloadFromStore()

        // Vecchi id spariti.
        #expect(!model.services.contains { $0.id == "ProjA/svc" })
        // Nuovi id presenti.
        #expect(model.services.contains { $0.id == "ProjANovo/svc" })
        // Il vecchio controller in esecuzione è stato fermato (rename == remove+add).
        let eventuallyDead = await waitUntil { !running.processAlive }
        #expect(eventuallyDead)
        // ProjB, non toccato dal rename, resta invariato.
        #expect(model.services.contains { $0.id == "ProjB/svc" })

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    // MARK: - restartProject / restartAll / clearProjectTerminals

    @Test func restartProjectRestartsOnlyAliveServicesOfThatProject() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let aliveA = try #require(model.services.first { $0.id == "ProjA/svc" })
        let stoppedB = try #require(model.services.first { $0.id == "ProjB/svc" })
        aliveA.start()
        _ = await waitUntil { aliveA.processAlive }
        let firstPID = aliveA.processID
        #expect(!stoppedB.processAlive)

        model.restartProject(named: "ProjA")

        // Il servizio vivo viene riavviato: resta vivo ma con un PID diverso.
        let restarted = await waitUntil { aliveA.processAlive && aliveA.processID != firstPID }
        #expect(restarted)
        // Il servizio fermo di ProjB non viene toccato (resta fermo, non avviato).
        #expect(!stoppedB.processAlive)

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func restartProjectLeavesNonAliveServicesOfThatProjectStopped() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let stoppedA = try #require(model.services.first { $0.id == "ProjA/svc" })
        #expect(!stoppedA.processAlive)

        model.restartProject(named: "ProjA")

        // Diamo un attimo per essere sicuri che nessuno start asincrono lo faccia partire.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!stoppedA.processAlive)
    }

    @Test func restartAllRestartsOnlyAliveServicesAcrossProjects() async throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let aliveA = try #require(model.services.first { $0.id == "ProjA/svc" })
        let stoppedB = try #require(model.services.first { $0.id == "ProjB/svc" })
        aliveA.start()
        _ = await waitUntil { aliveA.processAlive }
        let firstPID = aliveA.processID

        model.restartAll()

        let restarted = await waitUntil { aliveA.processAlive && aliveA.processID != firstPID }
        #expect(restarted)
        #expect(!stoppedB.processAlive)

        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func clearProjectTerminalsClearsOnlyThatProjectsLogs() throws {
        let store = try makeTwoProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        let a = try #require(model.services.first { $0.id == "ProjA/svc" })
        let b = try #require(model.services.first { $0.id == "ProjB/svc" })
        a.logs.ingest("linea A\n")
        b.logs.ingest("linea B\n")
        #expect(!a.logs.lines.isEmpty)
        #expect(!b.logs.lines.isEmpty)

        model.clearProjectTerminals(named: "ProjA")

        #expect(a.logs.lines.isEmpty)
        #expect(!b.logs.lines.isEmpty)
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

    // MARK: - templateSyncAvailable

    /// Progetto singolo importato da un template `.blauncher.json` che vive DENTRO la sua root
    /// (tracciato: `templateSync` valorizzato), su una cartella temporanea reale — necessario
    /// perché `checkTemplateSync` rilegge davvero il file dal disco.
    private func makeTrackedProjectStore() throws -> (store: ServiceStore, projectRoot: URL, templateFileURL: URL, originalData: Data) {
        // Fixture Skillera seminata ad hoc (l'init nudo parte vuoto): serve solo come
        // sorgente del template da esportare, poi viene rimossa.
        let store = ServiceStore.seededWithSkillera(fileURL: tempStoreURL())
        let exportRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
        let data = try store.exportTemplate(projectID: "Skillera", root: exportRoot)
        store.removeProject(id: "Skillera")

        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-appmodel-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let templateFileURL = projectRoot.appendingPathComponent("skillera.blauncher.json")
        try data.write(to: templateFileURL)
        _ = try store.importTemplate(data, root: projectRoot, sourceFileURL: templateFileURL)
        return (store, projectRoot, templateFileURL, data)
    }

    @Test func templateSyncAvailableEmptyWhenFileUnchanged() throws {
        let (store, _, _, _) = try makeTrackedProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)

        #expect(model.templateSyncAvailable.isEmpty)
    }

    @Test func reloadFromStoreDetectsChangedTemplateFile() throws {
        let (store, _, templateFileURL, originalData) = try makeTrackedProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)
        #expect(model.templateSyncAvailable.isEmpty)

        var template = try ProjectTemplateCodec.decode(originalData)
        template.profiles.append(StoredProfile(name: "Nuovo", serviceNames: []))
        try ProjectTemplateCodec.encode(template).write(to: templateFileURL)

        model.reloadFromStore()

        #expect(model.templateSyncAvailable == ["Skillera"])
    }

    @Test func syncProjectFromTemplateClearsAvailabilityAfterReload() throws {
        let (store, _, templateFileURL, originalData) = try makeTrackedProjectStore()
        let model = AppModel(store: store, pollingEnabled: false, crashNotificationsEnabled: false)

        var template = try ProjectTemplateCodec.decode(originalData)
        template.profiles.append(StoredProfile(name: "Nuovo", serviceNames: []))
        try ProjectTemplateCodec.encode(template).write(to: templateFileURL)
        model.reloadFromStore()
        #expect(model.templateSyncAvailable == ["Skillera"])

        try store.syncProjectFromTemplate(projectID: "Skillera")
        model.reloadFromStore()

        #expect(model.templateSyncAvailable.isEmpty)
    }
}
