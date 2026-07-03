import Foundation

/// Impostazioni globali dell'app, persistite in UserDefaults. `defaults` è iniettabile
/// per i test (mai lo `.standard` reale in suite). Ogni proprietà logge sia in lettura
/// che in scrittura: un valore fuori range scritto una volta (o rimasto da una versione
/// precedente dei limiti) non può mai essere osservato fuori range dai consumer.
@MainActor
enum AppSettings {
    static var defaults: UserDefaults = .standard

    private enum Keys {
        static let pollIntervalSeconds = "pollIntervalSeconds"
        static let killGracePeriodSeconds = "killGracePeriodSeconds"
        static let maxLogLines = "maxLogLines"
        static let crashNotificationsEnabled = "crashNotificationsEnabled"
    }

    /// Intervallo (secondi) tra due cicli di poll di stato/porte in AppModel. Default 2.
    static var pollIntervalSeconds: Double {
        get {
            let stored = defaults.object(forKey: Keys.pollIntervalSeconds) as? Double ?? 2
            return clampPollInterval(stored)
        }
        set { defaults.set(clampPollInterval(newValue), forKey: Keys.pollIntervalSeconds) }
    }

    /// Attesa (secondi) tra SIGTERM e SIGKILL forzato quando si ferma un servizio. Default 5.
    static var killGracePeriodSeconds: Double {
        get {
            let stored = defaults.object(forKey: Keys.killGracePeriodSeconds) as? Double ?? 5
            return clampKillGracePeriod(stored)
        }
        set { defaults.set(clampKillGracePeriod(newValue), forKey: Keys.killGracePeriodSeconds) }
    }

    /// Righe massime mantenute nel ring buffer di log per servizio. Default 5000.
    /// Si applica solo ai nuovi avvii (LogStore letto a init).
    static var maxLogLines: Int {
        get {
            let stored = defaults.object(forKey: Keys.maxLogLines) as? Int ?? 5000
            return clampMaxLogLines(stored)
        }
        set { defaults.set(clampMaxLogLines(newValue), forKey: Keys.maxLogLines) }
    }

    /// Se `false`, `CrashNotifier.notifyCrash` è un no-op. Default `true`.
    static var crashNotificationsEnabled: Bool {
        get { defaults.object(forKey: Keys.crashNotificationsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.crashNotificationsEnabled) }
    }

    private static func clampPollInterval(_ value: Double) -> Double {
        min(max(value, 1), 30)
    }

    private static func clampKillGracePeriod(_ value: Double) -> Double {
        min(max(value, 1), 30)
    }

    private static func clampMaxLogLines(_ value: Int) -> Int {
        min(max(value, 500), 50000)
    }
}
