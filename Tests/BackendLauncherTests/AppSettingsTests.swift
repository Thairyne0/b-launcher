import Foundation
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct AppSettingsTests {
    /// UserDefaults di scratch, isolato per test — mai lo `.standard` reale.
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
    }

    private func withScratchDefaults(_ body: () -> Void) {
        let previous = AppSettings.defaults
        AppSettings.defaults = scratchDefaults()
        defer { AppSettings.defaults = previous }
        body()
    }

    @Test func pollIntervalDefaultsWhenUnset() {
        withScratchDefaults {
            #expect(AppSettings.pollIntervalSeconds == 2)
        }
    }

    @Test func pollIntervalRoundTrips() {
        withScratchDefaults {
            AppSettings.pollIntervalSeconds = 7
            #expect(AppSettings.pollIntervalSeconds == 7)
        }
    }

    @Test func pollIntervalClampsBelowMinimumOnWrite() {
        withScratchDefaults {
            AppSettings.pollIntervalSeconds = 0
            #expect(AppSettings.pollIntervalSeconds == 1)
        }
    }

    @Test func pollIntervalClampsAboveMaximumOnWrite() {
        withScratchDefaults {
            AppSettings.pollIntervalSeconds = 999
            #expect(AppSettings.pollIntervalSeconds == 30)
        }
    }

    @Test func killGracePeriodDefaultsWhenUnset() {
        withScratchDefaults {
            #expect(AppSettings.killGracePeriodSeconds == 5)
        }
    }

    @Test func killGracePeriodRoundTrips() {
        withScratchDefaults {
            AppSettings.killGracePeriodSeconds = 12
            #expect(AppSettings.killGracePeriodSeconds == 12)
        }
    }

    @Test func killGracePeriodClampsBelowMinimumOnWrite() {
        withScratchDefaults {
            AppSettings.killGracePeriodSeconds = 0
            #expect(AppSettings.killGracePeriodSeconds == 1)
        }
    }

    @Test func killGracePeriodClampsAboveMaximumOnWrite() {
        withScratchDefaults {
            AppSettings.killGracePeriodSeconds = 999
            #expect(AppSettings.killGracePeriodSeconds == 30)
        }
    }

    @Test func maxLogLinesDefaultsWhenUnset() {
        withScratchDefaults {
            #expect(AppSettings.maxLogLines == 5000)
        }
    }

    @Test func maxLogLinesRoundTrips() {
        withScratchDefaults {
            AppSettings.maxLogLines = 1000
            #expect(AppSettings.maxLogLines == 1000)
        }
    }

    @Test func maxLogLinesClampsBelowMinimumOnWrite() {
        withScratchDefaults {
            AppSettings.maxLogLines = 0
            #expect(AppSettings.maxLogLines == 500)
        }
    }

    @Test func maxLogLinesClampsAboveMaximumOnWrite() {
        withScratchDefaults {
            AppSettings.maxLogLines = 999_999
            #expect(AppSettings.maxLogLines == 50000)
        }
    }

    @Test func crashNotificationsEnabledDefaultsToTrueWhenUnset() {
        withScratchDefaults {
            #expect(AppSettings.crashNotificationsEnabled == true)
        }
    }

    @Test func crashNotificationsEnabledRoundTrips() {
        withScratchDefaults {
            AppSettings.crashNotificationsEnabled = false
            #expect(AppSettings.crashNotificationsEnabled == false)
            AppSettings.crashNotificationsEnabled = true
            #expect(AppSettings.crashNotificationsEnabled == true)
        }
    }
}
