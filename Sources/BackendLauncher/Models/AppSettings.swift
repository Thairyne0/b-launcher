import AppKit
import Foundation

/// Aspetto dell'app: segue il sistema, oppure forza chiaro/scuro. `rawValue` è la forma
/// persistita in UserDefaults — stabile e indipendente dall'ordine dei case.
enum AppAppearance: String {
    case system
    case light
    case dark
}

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
        static let terminalFontSize = "terminalFontSize"
        static let appearance = "appearance"
        static let confirmStartAll = "confirmStartAll"
        static let confirmStopAll = "confirmStopAll"
        static let confirmStopProject = "confirmStopProject"
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

    /// Conferme di sicurezza dei bottoni di massa in toolbar: ciascuna disattivabile
    /// singolarmente dalle Impostazioni. Default `true` (popup attivo).
    static var confirmStartAll: Bool {
        get { defaults.object(forKey: Keys.confirmStartAll) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.confirmStartAll) }
    }

    static var confirmStopAll: Bool {
        get { defaults.object(forKey: Keys.confirmStopAll) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.confirmStopAll) }
    }

    static var confirmStopProject: Bool {
        get { defaults.object(forKey: Keys.confirmStopProject) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.confirmStopProject) }
    }

    /// Se `false`, `CrashNotifier.notifyCrash` è un no-op. Default `true`.
    static var crashNotificationsEnabled: Bool {
        get { defaults.object(forKey: Keys.crashNotificationsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.crashNotificationsEnabled) }
    }

    /// Dimensione (punti) del font monospace nel terminale log. Default 12.
    static var terminalFontSize: Double {
        get {
            let stored = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 12
            return clampTerminalFontSize(stored)
        }
        set { defaults.set(clampTerminalFontSize(newValue), forKey: Keys.terminalFontSize) }
    }

    /// Aspetto scelto in Impostazioni. Default `.system`; una stringa non riconosciuta
    /// (versione futura/passata dei case, o dato corrotto) ricade su `.system` invece di
    /// crashare o propagare `nil`.
    static var appearance: AppAppearance {
        get {
            guard let stored = defaults.string(forKey: Keys.appearance),
                  let value = AppAppearance(rawValue: stored) else {
                return .system
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    /// Applica `appearance` a `NSApp`: `nil` per `.system` (segue il sistema), altrimenti
    /// forza `.aqua`/`.darkAqua`. Va richiamata sia all'avvio (`AppDelegate`) sia subito dopo
    /// ogni cambio dal Picker in `SettingsView`, per uno switch live senza riavviare l'app.
    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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

    private static func clampTerminalFontSize(_ value: Double) -> Double {
        min(max(value, 9), 20)
    }
}
