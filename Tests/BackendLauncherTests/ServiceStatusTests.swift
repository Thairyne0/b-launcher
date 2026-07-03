import Testing
@testable import BackendLauncher

@Suite struct ServiceStatusTests {
    @Test func stoppedWhenNothing() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: false, lastExitCode: nil) == .stopped)
    }

    @Test func startingWhenAliveButPortClosed() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: false,
                                     stopRequested: false, lastExitCode: nil) == .starting)
    }

    @Test func runningWhenAliveAndPortOpen() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: true,
                                     stopRequested: false, lastExitCode: nil) == .running)
    }

    @Test func stoppingWhenAliveAndStopRequested() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: true,
                                     stopRequested: true, lastExitCode: nil) == .stopping)
    }

    @Test func crashedWhenDiedWithoutStopRequest() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: false, lastExitCode: 3) == .crashed(exitCode: 3))
    }

    @Test func stoppedAfterUserStop() {
        // user asked to stop, process exited: NOT a crash
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: true, lastExitCode: 0) == .stopped)
    }

    @Test func externalWhenPortOpenButNoProcess() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: true,
                                     stopRequested: false, lastExitCode: nil) == .external)
    }

    @Test func crashedTakesPrecedenceOverStalePortOpen() {
        // processo appena crashato ma l'ultimo poll della porta era ancora "aperta"
        #expect(ServiceStatus.derive(processAlive: false, portOpen: true,
                                     stopRequested: false, lastExitCode: 3) == .crashed(exitCode: 3))
    }

    @Test func stoppedAfterUserStopTakesPrecedenceOverStalePortOpen() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: true,
                                     stopRequested: true, lastExitCode: 0) == .stopped)
    }

    @Test func sixServicesConfigured() {
        #expect(ServiceConfig.all.count == 6)
        #expect(ServiceConfig.all.map(\.name) == ["gateway", "id", "atlas", "hr", "certet", "bill"])
        #expect(ServiceConfig.all.map(\.port) == [4000, 4001, 4003, 4006, 4010, 4012])
        for c in ServiceConfig.all {
            #expect(c.command == "npm run start:dev")
            #expect(c.workingDirectory.path.hasPrefix(ServiceConfig.projectRoot.path))
        }
    }
}
