import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@Suite struct ProcessStatsTests {
    @Test func samplePureMath() {
        let s = ProcessStats.sample(previousCPUSeconds: 1.0, currentCPUSeconds: 2.0,
                                     interval: 2, rssBytes: 104_857_600)
        #expect(abs(s.cpuPercent - 50.0) < 0.001)
        #expect(abs(s.rssMB - 100.0) < 0.001)
    }

    @Test func sampleClampsNegativeDeltaToZero() {
        let s = ProcessStats.sample(previousCPUSeconds: 5.0, currentCPUSeconds: 1.0,
                                     interval: 2, rssBytes: 0)
        #expect(s.cpuPercent == 0)
    }

    @Test func rusageOfSelf() {
        let info = ProcessStats.rusage(pid: getpid())
        let unwrapped = try? #require(info)
        #expect((unwrapped?.cpuSeconds ?? -1) > 0)
        #expect((unwrapped?.rssBytes ?? 0) > 10 * 1024 * 1024)
    }

    @Test func rusageOfDeadPidIsNil() {
        let candidate: pid_t = 99_999
        // se per qualche motivo il pid è vivo su questa macchina, salta il test
        // invece di produrre un falso negativo.
        guard kill(candidate, 0) != 0 else { return }
        #expect(ProcessStats.rusage(pid: candidate) == nil)
    }

    @Test func groupPIDsFindsOwnGroup() {
        let pids = ProcessStats.groupPIDs(pgid: getpgrp())
        #expect(pids.contains(getpid()))
    }

    @Test func groupTotalsPositiveForOwnGroup() {
        let totals = ProcessStats.groupTotals(pgid: getpgrp())
        #expect(totals.cpuSeconds > 0)
        #expect(totals.rssBytes > 0)
    }
}
