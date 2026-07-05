import Foundation
import Testing
@testable import BackendLauncher

@Suite struct CrashLoopDetectorTests {
    @Test func threeCrashesInWindowIsLoop() {
        var detector = CrashLoopDetector()
        let base = Date(timeIntervalSince1970: 1_000_000)
        detector.recordCrash(at: base)
        detector.recordCrash(at: base.addingTimeInterval(30))
        #expect(!detector.isLooping(at: base.addingTimeInterval(31)))
        detector.recordCrash(at: base.addingTimeInterval(60))
        #expect(detector.isLooping(at: base.addingTimeInterval(61)))
        #expect(detector.recentCrashCount(at: base.addingTimeInterval(61)) == 3)
    }

    @Test func crashesOutsideWindowExpire() {
        var detector = CrashLoopDetector()
        let base = Date(timeIntervalSince1970: 1_000_000)
        detector.recordCrash(at: base)
        detector.recordCrash(at: base.addingTimeInterval(10))
        detector.recordCrash(at: base.addingTimeInterval(20))
        // A +130s: il crash a +0 è fuori dalla finestra di 120s (130 > 120), quelli a
        // +10 (120 ≤ 120) e +20 restano dentro → 2 → non è loop.
        #expect(!detector.isLooping(at: base.addingTimeInterval(130)))
        #expect(detector.recentCrashCount(at: base.addingTimeInterval(130)) == 2)
    }

    @Test func resetClearsHistory() {
        var detector = CrashLoopDetector()
        let base = Date(timeIntervalSince1970: 1_000_000)
        detector.recordCrash(at: base)
        detector.recordCrash(at: base.addingTimeInterval(1))
        detector.recordCrash(at: base.addingTimeInterval(2))
        #expect(detector.isLooping(at: base.addingTimeInterval(3)))
        detector.reset()
        #expect(!detector.isLooping(at: base.addingTimeInterval(3)))
        #expect(detector.recentCrashCount(at: base.addingTimeInterval(3)) == 0)
    }
}
