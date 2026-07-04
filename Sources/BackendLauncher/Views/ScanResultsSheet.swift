import SwiftUI

/// Sheet di esito scansione cartella (`ProjectScanner.scan(root:)`): mostra i servizi
/// riconosciuti con un toggle di inclusione, propone un nome progetto, e crea il progetto
/// nello store alla conferma. Editing completo (comando, readiness, icona) resta fuori scope:
/// disponibile dopo, via "Modifica…" sul servizio già creato — qui solo l'inclusione/esclusione
/// per tenere lo sheet semplice e veloce da attraversare.
struct ScanResultsSheet: View {
    var model: AppModel
    var scanResult: ProjectScanner.ScanResult
    var root: URL
    var onDismiss: () -> Void
    /// Chiamato con l'id del progetto appena creato, cosicché il chiamante (`ContentView`, che
    /// possiede il binding di selezione della sidebar) possa navigare direttamente sul nuovo
    /// progetto. `nil` di default: i chiamanti che non se ne curano non devono valorizzarlo.
    var onCreated: ((String) -> Void)? = nil

    @State private var projectName: String
    @State private var includedServiceIDs: Set<String>
    @State private var includeInfraCheck = true
    @State private var errorMessage: String?

    init(model: AppModel,
         scanResult: ProjectScanner.ScanResult,
         root: URL,
         onDismiss: @escaping () -> Void,
         onCreated: ((String) -> Void)? = nil) {
        self.model = model
        self.scanResult = scanResult
        self.root = root
        self.onDismiss = onDismiss
        self.onCreated = onCreated
        _projectName = State(initialValue: scanResult.suggestedProjectName)
        // Tutti i servizi trovati partono selezionati (default ON, come da spec).
        _includedServiceIDs = State(initialValue: Set(scanResult.services.map(\.id)))
    }

    private var trimmedName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unicità case-insensitive contro i progetti esistenti dello store — stessa regola
    /// applicata da `ServiceStore.addProject`, verificata qui in anticipo per un errore
    /// inline immediato invece di aspettare il fallimento di `addProject`.
    private var nameError: String? {
        guard !trimmedName.isEmpty else { return "Il nome progetto non può essere vuoto." }
        let collides = model.store?.projects.contains {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        } ?? false
        if collides { return "Esiste già un progetto chiamato \"\(trimmedName)\"." }
        return nil
    }

    private var selectedCount: Int {
        scanResult.services.count(where: { includedServiceIDs.contains($0.id) })
    }

    private var canCreate: Bool {
        nameError == nil && selectedCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if scanResult.services.isEmpty {
                emptyState
            } else {
                Divider()
                nameField
                Divider()
                serviceList
                if let infraCheck = scanResult.suggestedInfraCheck {
                    Divider()
                    infraToggleRow(infraCheck)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Divider()
                footer
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Backend trovati")
                .font(.title2.weight(.semibold))
            Text(root.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label("Nessun backend riconosciuto", systemImage: "questionmark.folder")
            } description: {
                Text("Nessun backend riconosciuto in questa cartella. Prova il wizard \"Nuovo progetto\" per configurarlo manualmente, oppure genera un template con Claude Code.")
            }
            Spacer()
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nome progetto").font(.headline)
            TextField("Nome progetto", text: $projectName)
                .textFieldStyle(.roundedBorder)
            if let nameError, !trimmedName.isEmpty {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backend (\(selectedCount)/\(scanResult.services.count) selezionati)")
                .font(.headline)
            List(scanResult.services) { service in
                serviceRow(service)
            }
            .listStyle(.plain)
            .frame(minHeight: 220)
        }
    }

    private func serviceRow(_ service: ProjectScanner.ScannedService) -> some View {
        Toggle(isOn: Binding(
            get: { includedServiceIDs.contains(service.id) },
            set: { isOn in
                if isOn { includedServiceIDs.insert(service.id) } else { includedServiceIDs.remove(service.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.body)
                Text(service.sourceHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(service.command) · \(readinessSummary(service.readiness))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func infraToggleRow(_ infraCheck: StoredInfraCheck) -> some View {
        Toggle(isOn: $includeInfraCheck) {
            Text("Spia infrastruttura: \(infraCheck.label) :\(infraCheck.port)")
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("Porta o comando sbagliati? Dopo la creazione: tasto destro sul backend in sidebar → Modifica…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crea progetto (\(selectedCount))") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
    }

    /// Riepilogo leggibile della readiness per una riga di servizio: "porta 4000" / "via log"
    /// / "sempre pronto", coerente col linguaggio già usato altrove nell'app.
    private func readinessSummary(_ readiness: StoredReadiness) -> String {
        switch readiness.kind {
        case .port:
            return "porta \(readiness.port ?? 0)"
        case .logMarker:
            return "via log"
        case .processAlive:
            return "sempre pronto"
        }
    }

    /// Crea il progetto e aggiunge i servizi selezionati, nell'ordine dello scan. Su errore di
    /// `addProject` (nome non valido/duplicato sfuggito alla validazione inline) l'intero flusso
    /// si ferma prima di creare qualunque cosa. Su errore di `addService` per UN servizio (es.
    /// collisione di nome tra due candidati con lo stesso nome cartella — raro ma possibile),
    /// il progetto resta comunque creato con i servizi aggiunti fino a quel punto: nessun
    /// rollback automatico (lo store non lo supporta), l'errore viene mostrato inline e l'utente
    /// può sistemare da "Aggiungi backend"/"Modifica…" dopo aver chiuso lo sheet.
    private func createProject() {
        guard let store = model.store else { return }
        do {
            try store.addProject(named: trimmedName)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let projectID = trimmedName
        var addedCount = 0
        for service in scanResult.services where includedServiceIDs.contains(service.id) {
            let absoluteDirectory = service.relativeDirectory.isEmpty
                ? root
                : root.appendingPathComponent(service.relativeDirectory)
            let stored = StoredService(
                name: service.name,
                directory: absoluteDirectory.path,
                command: service.command,
                readiness: service.readiness,
                symbolName: nil
            )
            do {
                try store.addService(stored, toProject: projectID)
                addedCount += 1
            } catch {
                errorMessage = error.localizedDescription
                model.reloadFromStore()
                return
            }
        }

        if includeInfraCheck, let infraCheck = scanResult.suggestedInfraCheck {
            try? store.updateInfraCheck(projectID: projectID, infraCheck: infraCheck)
        }

        model.reloadFromStore()
        ToastCenter.shared.show("Progetto \(trimmedName) creato con \(addedCount) backend", systemImage: "checkmark.circle.fill")
        onCreated?(projectID)
        onDismiss()
    }
}
