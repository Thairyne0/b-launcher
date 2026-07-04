import SwiftUI

/// Finestra Impostazioni dell'app (⌘,), aperta dalla scene `Settings` in BackendLauncherApp.
/// Legge/scrive direttamente `AppSettings` (UserDefaults): lo stato locale qui è solo per
/// pilotare gli Slider/Stepper — ogni modifica viene scritta subito via `onChange`, quindi
/// non serve alcun pulsante "Salva".
struct SettingsView: View {
    @State private var pollIntervalSeconds: Double = AppSettings.pollIntervalSeconds
    @State private var killGracePeriodSeconds: Double = AppSettings.killGracePeriodSeconds
    @State private var maxLogLines: Double = Double(AppSettings.maxLogLines)
    @State private var crashNotificationsEnabled: Bool = AppSettings.crashNotificationsEnabled
    @State private var terminalFontSize: Double = AppSettings.terminalFontSize
    @State private var appearance: AppAppearance = AppSettings.appearance

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $pollIntervalSeconds, in: 1...30, step: 1) {
                        Text("Intervallo aggiornamento stato")
                    }
                    Text("Ogni \(Int(pollIntervalSeconds)) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: $killGracePeriodSeconds, in: 1...30, step: 1) {
                    Text("Attesa prima di kill forzato: \(Int(killGracePeriodSeconds)) s")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $maxLogLines, in: 500...50000, step: 500) {
                        Text("Righe massime per terminale: \(Int(maxLogLines))")
                    }
                    Text("Vale per i nuovi avvii")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $terminalFontSize, in: 9...20, step: 1) {
                        Text("Dimensione testo terminale")
                    }
                    Text("\(Int(terminalFontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Aspetto", selection: $appearance) {
                    Text("Sistema").tag(AppAppearance.system)
                    Text("Chiaro").tag(AppAppearance.light)
                    Text("Scuro").tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Notifiche di crash", isOn: $crashNotificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
        .onChange(of: pollIntervalSeconds) { _, newValue in
            AppSettings.pollIntervalSeconds = newValue
        }
        .onChange(of: killGracePeriodSeconds) { _, newValue in
            AppSettings.killGracePeriodSeconds = newValue
        }
        .onChange(of: maxLogLines) { _, newValue in
            AppSettings.maxLogLines = Int(newValue)
        }
        .onChange(of: crashNotificationsEnabled) { _, newValue in
            AppSettings.crashNotificationsEnabled = newValue
        }
        .onChange(of: terminalFontSize) { _, newValue in
            AppSettings.terminalFontSize = newValue
        }
        .onChange(of: appearance) { _, newValue in
            AppSettings.appearance = newValue
            AppSettings.applyAppearance()
        }
    }
}
