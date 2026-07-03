import Foundation
import UserNotifications

/// Notifiche locali macOS per i crash dei backend.
/// Richiede identità di bundle: da `swift run` (binario nudo) le API UN* non sono
/// disponibili → no-op silenzioso. Dal bundle .app funziona.
@MainActor
enum CrashNotifier {
    private static var authRequested = false

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable, !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyCrash(service: String, exitCode: Int32) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service) è crashato"
        content.body = "Exit code \(exitCode). Riavvialo dal launcher."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
