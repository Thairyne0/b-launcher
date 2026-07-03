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
}
