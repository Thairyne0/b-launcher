import Foundation
import Testing
@testable import BackendLauncher

@Suite struct StartOrchestratorTests {
    @Test func noDependenciesSingleWave() {
        let waves = StartOrchestrator.waves(services: [
            (name: "a", startAfter: []),
            (name: "b", startAfter: []),
        ])
        #expect(waves == [["a", "b"]])
    }

    @Test func linearChainMakesOneWavePerService() {
        let waves = StartOrchestrator.waves(services: [
            (name: "c", startAfter: ["b"]),
            (name: "a", startAfter: []),
            (name: "b", startAfter: ["a"]),
        ])
        #expect(waves == [["a"], ["b"], ["c"]])
    }

    @Test func diamondResolvesInThreeWaves() {
        // a → (b, c) → d
        let waves = StartOrchestrator.waves(services: [
            (name: "d", startAfter: ["b", "c"]),
            (name: "b", startAfter: ["a"]),
            (name: "c", startAfter: ["a"]),
            (name: "a", startAfter: []),
        ])
        #expect(waves == [["a"], ["b", "c"], ["d"]])
    }

    @Test func cycleReturnsNil() {
        let waves = StartOrchestrator.waves(services: [
            (name: "a", startAfter: ["b"]),
            (name: "b", startAfter: ["a"]),
        ])
        #expect(waves == nil)
    }

    @Test func selfDependencyIsACycle() {
        #expect(StartOrchestrator.waves(services: [(name: "a", startAfter: ["a"])]) == nil)
    }
}
