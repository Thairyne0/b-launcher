import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tipo di readiness selezionabile nel form — rispecchia `StoredReadiness.Kind` ma vive
/// separato per poter guidare quali campi extra mostrare senza impacchettare gli stati
/// intermedi (es. porta non ancora valida) nel modello persistito.
private enum ReadinessKind: String, CaseIterable, Identifiable {
    case port = "Porta TCP"
    case logMarker = "Marker nei log"
    case processAlive = "Sempre pronto (processo vivo)"
    var id: String { rawValue }
}

/// Preset di icone SF Symbol selezionabili per un servizio. `nil` (rappresentato dal primo
/// elemento) è il default "server.rack" già usato ovunque nella UI quando `symbolName` è assente.
private enum ServiceIconPreset: CaseIterable, Identifiable {
    case defaultServer
    case globe
    case database
    case bolt
    case shippingBox
    case terminal
    case antenna
    case gears

    var id: String { symbolName ?? "default" }

    var symbolName: String? {
        switch self {
        case .defaultServer: nil
        case .globe: "globe"
        case .database: "cylinder.split.1x2"
        case .bolt: "bolt.fill"
        case .shippingBox: "shippingbox.fill"
        case .terminal: "terminal.fill"
        case .antenna: "antenna.radiowaves.left.and.right"
        case .gears: "gearshape.2.fill"
        }
    }

    /// Nome sempre concreto per il rendering (default incluso), a differenza di `symbolName`
    /// che è `nil` per il default per farlo combaciare con `StoredService.symbolName`.
    var displaySymbolName: String { symbolName ?? "server.rack" }
}

/// Sheet di aggiunta/modifica di un servizio all'interno di un progetto. Usato sia in
/// modalità "add" (nessun servizio esistente) sia "edit" (prefilled, rename supportato).
struct ServiceFormSheet: View {
    enum Mode {
        case add
        case edit(originalName: String)
    }

    var model: AppModel
    var projectID: String
    var mode: Mode
    var onDismiss: () -> Void

    @State private var folderURL: URL?
    @State private var name: String = ""
    @State private var command: String = "npm run start:dev"
    @State private var readinessKind: ReadinessKind = .logMarker
    @State private var portText: String = ""
    @State private var marker: String = "successfully started"
    @State private var symbolName: String?
    @State private var saveError: String?
    /// Evita di mostrare "il nome non può essere vuoto" prima ancora che l'utente abbia
    /// interagito col form (fastidioso in modalità "add" a sheet appena aperta).
    @State private var nameFieldTouched = false

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingProject: StoredProject? {
        model.store?.projects.first { $0.id == projectID }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsUnique: Bool {
        guard let project = existingProject else { return true }
        let originalName: String? = {
            if case .edit(let original) = mode { return original }
            return nil
        }()
        return !project.services.contains { service in
            if let originalName, service.name.caseInsensitiveCompare(originalName) == .orderedSame {
                return false  // il servizio che stiamo modificando non conta come collisione con se stesso
            }
            return service.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var nameError: String? {
        if trimmedName.isEmpty { return "Il nome non può essere vuoto." }
        if !nameIsUnique { return "Esiste già un backend chiamato \"\(trimmedName)\" in questo progetto." }
        return nil
    }

    private var portValue: UInt16? {
        // 0 non è una porta TCP utilizzabile: rifiutata esplicitamente.
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else { return nil }
        return port
    }

    private var markerIsValid: Bool {
        !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var readinessIsValid: Bool {
        switch readinessKind {
        case .port: portValue != nil
        case .logMarker: markerIsValid
        case .processAlive: true
        }
    }

    private var folderIsMissing: Bool {
        guard let folderURL else { return false }
        return !FileManager.default.fileExists(atPath: folderURL.path)
    }

    /// Vero se il comando (case-insensitive) menziona "docker" — euristica semplice per
    /// avvisare che il launcher non ferma i container: lo stop termina solo il processo del
    /// comando (es. `docker compose up`), non i container che ha lanciato.
    private var commandLooksLikeDocker: Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("docker")
    }

    private var canSave: Bool {
        nameError == nil && folderURL != nil && readinessIsValid && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditMode ? "Modifica backend" : "Aggiungi backend")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Cartella").font(.headline)
                HStack {
                    Text(folderURL?.path ?? "Nessuna cartella selezionata")
                        .font(.callout)
                        .foregroundStyle(folderURL == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Scegli…") { chooseFolder() }
                }
                if folderIsMissing {
                    Label("La cartella non esiste (ancora) su disco — puoi salvare comunque.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nome").font(.headline)
                TextField("es. gateway", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, _ in nameFieldTouched = true }
                if let nameError, nameFieldTouched || isEditMode {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Comando").font(.headline)
                TextField("npm run start:dev", text: $command)
                    .textFieldStyle(.roundedBorder)
                if commandLooksLikeDocker {
                    Label("I container Docker non vengono fermati dal launcher: lo stop termina solo il comando. Prevedi uno stop manuale (docker compose down).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prontezza").font(.headline)
                Picker("", selection: $readinessKind) {
                    ForEach(ReadinessKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch readinessKind {
                case .port:
                    TextField("Porta (es. 4000)", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    if portValue == nil && !portText.isEmpty {
                        Text("Porta non valida (1–65535).")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                case .logMarker:
                    TextField("Testo da cercare nei log", text: $marker)
                        .textFieldStyle(.roundedBorder)
                    if !markerIsValid {
                        Text("Il marker non può essere vuoto.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                case .processAlive:
                    Text("Il backend è considerato pronto non appena il processo parte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            iconSection

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salva") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: prefillIfEditing)
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Icona").font(.headline)
            HStack(spacing: 10) {
                ForEach(ServiceIconPreset.allCases) { preset in
                    iconOption(preset)
                }
            }
        }
    }

    private func iconOption(_ preset: ServiceIconPreset) -> some View {
        let isSelected = symbolName == preset.symbolName
        return Button {
            symbolName = preset.symbolName
        } label: {
            Image(systemName: preset.displaySymbolName)
                .imageScale(.medium)
                .frame(width: 28, height: 28)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                            in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(preset.displaySymbolName)
    }

    /// NSOpenPanel diretto: `.fileImporter` da una sheet modale è inaffidabile su macOS.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Scegli la cartella del backend"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url
        if trimmedName.isEmpty {
            name = url.lastPathComponent
        }
    }

    private func prefillIfEditing() {
        guard case .edit(let originalName) = mode,
              let project = existingProject,
              let service = project.services.first(where: { $0.name == originalName }) else { return }
        name = service.name
        command = service.command
        folderURL = URL(fileURLWithPath: service.directory)
        switch service.readiness.kind {
        case .port:
            readinessKind = .port
            portText = service.readiness.port.map(String.init) ?? ""
        case .logMarker:
            readinessKind = .logMarker
            marker = service.readiness.marker ?? "successfully started"
        case .processAlive:
            readinessKind = .processAlive
        }
        symbolName = service.symbolName
    }

    private func save() {
        guard let store = model.store, let folderURL else { return }
        let readiness: StoredReadiness
        switch readinessKind {
        case .port:
            readiness = StoredReadiness(kind: .port, port: portValue, marker: nil)
        case .logMarker:
            readiness = StoredReadiness(kind: .logMarker, port: nil,
                                        marker: marker.trimmingCharacters(in: .whitespacesAndNewlines))
        case .processAlive:
            readiness = StoredReadiness(kind: .processAlive, port: nil, marker: nil)
        }
        let service = StoredService(name: trimmedName, directory: folderURL.path,
                                    command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                                    readiness: readiness, symbolName: symbolName)
        do {
            switch mode {
            case .add:
                try store.addService(service, toProject: projectID)
            case .edit(let originalName):
                try store.updateService(named: originalName, inProject: projectID, with: service)
            }
            model.reloadFromStore()
            onDismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
