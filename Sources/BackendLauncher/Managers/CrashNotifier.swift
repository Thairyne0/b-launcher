import Foundation
import UserNotifications

/// Notifiche locali macOS per i crash dei backend.
/// Richiede identità di bundle: da `swift run` (binario nudo) le API UN* non sono
/// disponibili → no-op silenzioso. Dal bundle .app funziona.
@MainActor
enum CrashNotifier {
    private static var authRequested = false

    /// Delegate condiviso: gestisce il tap sulla notifica (deep-link) e la presentazione
    /// anche ad app in primo piano. Assegnato al UNUserNotificationCenter solo quando
    /// `isAvailable`, in requestAuthorizationIfNeeded.
    static let delegate = NotificationDelegate()

    /// Impostato dall'AppDelegate: riceve l'id (config.id, namespaced "Progetto/nome") del
    /// servizio la cui notifica di crash è stata toccata dall'utente.
    static var onNotificationTap: ((String) -> Void)?

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable, !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().delegate = Self.delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `service` è il nome visualizzato (usato nel titolo); `serviceID` è config.id
    /// (namespaced), portato nello userInfo per il deep-link al tap (AppModel.revealService
    /// fa match esatto sull'id, con fallback sul nome breve per notifiche pre-namespacing).
    static func notifyCrash(service: String, serviceID: String, exitCode: Int32) {
        guard isAvailable, AppSettings.crashNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service) è crashato"
        content.body = "Exit code \(exitCode). Riavvialo dal launcher."
        content.sound = .default
        content.userInfo = ["service": serviceID]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Notifica di RECOVERY: un servizio che era crashato è tornato pronto (verde).
    /// Chiude il cerchio della notifica di crash — stesso gate delle impostazioni.
    static func notifyRecovery(service: String, serviceID: String) {
        guard isAvailable, AppSettings.crashNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service) è tornato verde"
        content.body = "Di nuovo in esecuzione e pronto."
        content.userInfo = ["service": serviceID]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Riceve gli eventi dello UNUserNotificationCenter: tap (deep-link) e presentazione
/// mentre l'app è in primo piano.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let service = response.notification.request.content.userInfo["service"] as? String {
            await MainActor.run { CrashNotifier.onNotificationTap?(service) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]  // mostra anche con app in primo piano
    }
}
