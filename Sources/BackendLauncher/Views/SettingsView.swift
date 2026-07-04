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
    @State private var confirmStartAll: Bool = AppSettings.confirmStartAll
    @State private var confirmStopAll: Bool = AppSettings.confirmStopAll
    @State private var confirmStopProject: Bool = AppSettings.confirmStopProject
    /// `nil` = nessun check ancora fatto in questa apertura delle Impostazioni.
    @State private var updateStatus: UpdateChecker.Status?
    @State private var checkingUpdates = false

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

            Section("Aggiornamenti") {
                if let repoPath = UpdateChecker.repoPath {
                    HStack {
                        Button(checkingUpdates ? "Controllo…" : "Controlla aggiornamenti") {
                            checkUpdates(repoPath: repoPath)
                        }
                        .disabled(checkingUpdates)
                        Spacer()
                        if case .behind = updateStatus {
                            Button("Aggiorna e riavvia…") {
                                UpdateChecker.runUpdateInTerminal(repoPath: repoPath)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    updateStatusLabel
                    Text("L'aggiornamento esegue \"make update\" in Terminale nel clone: pull, rebuild locale e reinstallazione (l'app si chiude e si riapre da sola).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Non disponibile: app avviata fuori dal bundle installato, oppure il clone da cui è stata buildata non esiste più.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Conferme di sicurezza") {
                Toggle("Chiedi conferma per \"Avvia tutti\"", isOn: $confirmStartAll)
                Toggle("Chiedi conferma per \"Ferma tutti\"", isOn: $confirmStopAll)
                Toggle("Chiedi conferma per \"Ferma progetto\"", isOn: $confirmStopProject)
                Text("Valgono per i bottoni della toolbar. Disattivando, l'azione parte subito al click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 600)
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
        .onChange(of: confirmStartAll) { _, newValue in
            AppSettings.confirmStartAll = newValue
        }
        .onChange(of: confirmStopAll) { _, newValue in
            AppSettings.confirmStopAll = newValue
        }
        .onChange(of: confirmStopProject) { _, newValue in
            AppSettings.confirmStopProject = newValue
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updateStatus {
        case nil:
            EmptyView()
        case .upToDate:
            Label("Sei all'ultima versione.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .behind(let commits):
            Label(commits == 1 ? "1 aggiornamento disponibile."
                               : "\(commits) aggiornamenti disponibili.",
                  systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `check` spawna git e può toccare la rete: fuori dal MainActor.
    private func checkUpdates(repoPath: String) {
        checkingUpdates = true
        updateStatus = nil
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                UpdateChecker.check(repoPath: repoPath)
            }.value
            updateStatus = status
            checkingUpdates = false
        }
    }
}
