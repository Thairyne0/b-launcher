import SwiftUI
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

    // MARK: - label/color (A4: exit 0 is a clean stop, not a crash, in the UI)

    @Test func crashedWithNonZeroExitCodeLabelUnchanged() {
        #expect(ServiceStatus.crashed(exitCode: 7).label == "crash (exit 7)")
        #expect(ServiceStatus.crashed(exitCode: 7).color == .red)
    }

    @Test func crashedWithZeroExitCodeHasTerminatedLabelAndOrangeColor() {
        #expect(ServiceStatus.crashed(exitCode: 0).label == "terminato (exit 0)")
        #expect(ServiceStatus.crashed(exitCode: 0).color == .orange)
    }

    @Test func sixServicesConfigured() {
        #expect(ServiceConfig.all.count == 6)
        #expect(ServiceConfig.all.map(\.name) == ["gateway", "id", "atlas", "hr", "certet", "bill"])
        #expect(ServiceConfig.all.map(\.port) == [4000, 4001, nil, nil, nil, nil])
        for c in ServiceConfig.all {
            #expect(c.command == "npm run start:dev")
            #expect(c.workingDirectory.path.hasPrefix(ServiceConfig.projectRoot.path))
        }
    }
}
