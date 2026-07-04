import AppKit
import SwiftUI

/// Sheet di creazione del `.env` per un servizio che ne è privo (badge ".env mancante").
/// L'utente incolla il contenuto ricevuto da un collega o lo importa da un file; il launcher
/// crea `workingDirectory/.env` via `EnvFileWriter` (mai sovrascrittura, permessi 0600).
/// Il contenuto incollato vive SOLO nello stato di questa view e nel file finale: mai nei
/// log, nei toast, nei messaggi d'errore o in qualsiasi persistenza del launcher.
struct EnvCreateSheet: View {
    let serviceName: String
    let directory: URL

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    /// `nil` = verifica `.gitignore` ancora in corso.
    @State private var gitStatus: EnvFileWriter.GitIgnoreStatus?
    @State private var riskAccepted = false
    @State private var errorMessage: String?

    private var keyCount: Int { EnvFileWriter.envKeyCount(content) }
    private var contentIsEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// `.notIgnored`/`.unknown` richiedono la conferma esplicita del rischio; finché la
    /// verifica è in corso (`nil`) il bottone resta disabilitato.
    private var needsRiskConfirmation: Bool {
        gitStatus == .notIgnored || gitStatus == .unknown
    }
    private var canCreate: Bool {
        !contentIsEmpty && gitStatus != nil && (!needsRiskConfirmation || riskAccepted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crea .env per \(serviceName)")
                .font(.title3.weight(.semibold))

            Text("Il file verrà creato in \(directory.appendingPathComponent(".env").path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            // `scrollContentBackground(.hidden)` + sfondo proprio: il background di default
            // dell'NSTextView non segue il raggio dell'angolo e stona sul glass della sheet.
            // Placeholder: leading 13 = 8 di padding editor + 5 di `lineFragmentPadding`
            // dell'NSTextView sottostante, così è allineato al primo carattere digitato.
            TextEditor(text: $content)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 190)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("Incolla qui il contenuto del .env (es. ricevuto da un collega)…")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                    }
                }

            if !contentIsEmpty {
                Label(keyCount == 1 ? "1 variabile rilevata" : "\(keyCount) variabili rilevate",
                      systemImage: keyCount > 0 ? "checkmark.circle" : "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(keyCount > 0 ? Color.secondary : Color.orange)
                    .help(keyCount > 0
                          ? "Righe nel formato CHIAVE=valore"
                          : "Nessuna riga CHIAVE=valore riconosciuta: sicuro che sia un .env?")
            }

            gitStatusRow

            if needsRiskConfirmation {
                Toggle("Ho capito il rischio: crea comunque il file", isOn: $riskAccepted)
                    .font(.caption)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Importa da file…") { importFromFile() }
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crea .env") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            // `gitIgnoreStatus` spawna `git`: fuori dal MainActor per non bloccare la UI.
            let dir = directory
            gitStatus = await Task.detached(priority: .userInitiated) {
                EnvFileWriter.gitIgnoreStatus(for: dir)
            }.value
        }
    }

    @ViewBuilder
    private var gitStatusRow: some View {
        switch gitStatus {
        case nil:
            Label("Controllo del .gitignore in corso…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ignored:
            Label(".env è coperto dal .gitignore: non finirà nei commit.",
                  systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .noRepo:
            Label("La cartella non è un repository git: nessun rischio di commit.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notIgnored:
            Label("Attenzione: .env NON è ignorato da git — rischio di committare i segreti. Chiedi al team di aggiungerlo al .gitignore.",
                  systemImage: "exclamationmark.shield.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .unknown:
            Label("Impossibile verificare il .gitignore (git non disponibile?).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Carica il contenuto di un file nell'editor (per revisione: la creazione resta un
    /// passo esplicito). Il nome del file scelto è irrilevante: la destinazione è sempre
    /// `.env` nella working directory del servizio.
    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true  // i file .env* sono nascosti
        panel.message = "Scegli il file con il contenuto dell'env"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 1_000_000 else {
            errorMessage = "File troppo grande (oltre 1 MB): non sembra un .env."
            return
        }
        if let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
            content = text
            errorMessage = nil
        } else {
            errorMessage = "Impossibile leggere il file come testo."
        }
    }

    private func create() {
        do {
            try EnvFileWriter.createEnvFile(in: directory, content: content)
            ToastCenter.shared.show("File .env creato per \(serviceName)")
            dismiss()
        } catch EnvFileWriter.EnvWriteError.alreadyExists {
            errorMessage = "Un file .env esiste già in questa cartella (creato nel frattempo?). Nessuna modifica fatta."
        } catch EnvFileWriter.EnvWriteError.directoryMissing {
            errorMessage = "La cartella del servizio non esiste più."
        } catch {
            errorMessage = "Creazione fallita (\(error))."
        }
    }
}
