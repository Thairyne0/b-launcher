import Foundation
import Testing
@testable import BackendLauncher

/// Config fittizia: comandi brevi al posto di npm. cwd=/tmp esiste sempre.
private func fakeConfig(command: String) -> ServiceConfig {
    ServiceConfig(name: "fake", directory: "", port: 1, command: command)
}

@MainActor
@Suite struct ServiceControllerTests {
    @Test func crashSetsCrashedStatusWithExitCode() async {
        let c = ServiceController(config: fakeConfig(command: "exit 7"), cwd: "/tmp")
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashed)
    }

    @Test func userStopEndsInStoppedNotCrashed() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        let alive = await waitUntil { c.status == .starting }
        #expect(alive)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func restartSpawnsNewProcess() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.processID != nil }
        let firstPID = c.processID
        c.restart()
        let restarted = await waitUntil { c.processID != nil && c.processID != firstPID }
        #expect(restarted)
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func startWhilePortExternallyOpenIsRefused() async {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let config = ServiceConfig(name: "fake", directory: "", port: listener.port, command: "sleep 60")
        let c = ServiceController(config: config, cwd: "/tmp")
        c.portOpen = true
        #expect(c.status == .external)
        c.start()  // deve rifiutare: niente processo
        #expect(c.processID == nil)
    }

    @Test func runningWhenAliveAndPortMarkedOpen() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.portOpen = true
        #expect(c.status == .running)
        c.stop()
        _ = await waitUntil { c.processID == nil }
    }

    @Test func restartAfterCrashStartsFresh() async {
        let c = ServiceController(config: fakeConfig(command: "exit 7"), cwd: "/tmp")
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashed)
        c.restart()
        // restart() da .crashed NON è un no-op: start() è sincrono, quindi qui il
        // nuovo processo è già partito (nessun await tra restart e questo expect).
        #expect(c.status == .starting)
        // il nuovo "exit 7" esce di nuovo → di nuovo .crashed
        let crashedAgain = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashedAgain)
        // esattamente due banner di avvio nei log: il secondo start è avvenuto davvero
        #expect(c.logs.lines.filter { $0.text.contains("── avvio") }.count == 2)
    }

    @Test func spawnFailureBecomesCrashedMinusOne() async {
        let c = ServiceController(config: fakeConfig(command: "true"), cwd: "/nonexistent/xyz")
        c.start()
        #expect(c.status == .crashed(exitCode: -1))
    }
}
