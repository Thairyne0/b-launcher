import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet di import di un template di progetto (`.blauncher.json`, letto come `.json` generico —
/// registrare uno UTType custom per l'estensione non vale la complessità per un file picker).
/// Flusso: 1) scegli il file → mostra nome template + n servizi; 2) scegli la root sul TUO
/// Mac dove vive il repo; 3) eventualmente rinomina (prefilled, utile in caso di collisione);
/// 4) Importa.
///
/// NOTA: i picker usano NSOpenPanel diretto invece di `.fileImporter` — due `.fileImporter`
/// sulla stessa view non funzionano (limite SwiftUI documentato: solo l'ultimo si presenta),
/// e da una sheet modale anche il singolo importer è inaffidabile su macOS.
struct ImportTemplateSheet: View {
    var model: AppModel
    var onDismiss: () -> Void

    @State private var loadedTemplate: ProjectTemplate?
    @State private var rootURL: URL?
    @State private var projectName: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Importa progetto")
                .font(.title2.weight(.semibold))

            if let loadedTemplate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Template").font(.headline)
                    Text("\"\(loadedTemplate.name)\" — \(loadedTemplate.services.count) backend")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dove si trova il progetto sul TUO Mac?").font(.headline)
                    HStack {
                        Text(rootURL?.path ?? "Nessuna cartella selezionata")
                            .font(.callout)
                            .foregroundStyle(rootURL == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Scegli…") { chooseRootFolder() }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Nome progetto").font(.headline)
                    TextField("Nome progetto", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button("Annulla", role: .cancel) { onDismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Importa") { importTemplate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(rootURL == nil || projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("Scegli il file .blauncher.json esportato da un collega.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("Annulla", role: .cancel) { onDismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Scegli file…") { chooseTemplateFile() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func chooseTemplateFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Scegli il template di progetto (.blauncher.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let template = try ProjectTemplateCodec.decode(data)
            loadedTemplate = template
            projectName = template.name
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Scegli la cartella dove si trova il progetto su questo Mac"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL = url
    }

    private func importTemplate() {
        guard let store = model.store, let loadedTemplate, let rootURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(loadedTemplate)
            let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try store.importTemplate(data, root: rootURL, nameOverride: trimmedName)
            model.reloadFromStore()
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
