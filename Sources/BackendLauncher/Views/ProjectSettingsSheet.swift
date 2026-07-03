import SwiftUI

/// Sheet "Impostazioni progetto": rinomina, check infrastruttura, profili di avvio — tutto in
/// un unico salvataggio applicato in ordine (rename -> infra -> profili), che si ferma al primo
/// errore e lo mostra inline senza chiudere lo sheet (nessuna scrittura parziale visibile
/// all'utente oltre a quella già persistita dallo store per lo step riuscito).
struct ProjectSettingsSheet: View {
    var model: AppModel
    var projectID: String
    var onDismiss: () -> Void

    @State private var name: String = ""
    @State private var showInfraCheck = false
    @State private var infraLabel: String = "NATS"
    @State private var infraPortText: String = ""
    @State private var profiles: [EditableProfile] = []
    @State private var accentColorHex: String?
    @State private var saveError: String?

    private var project: StoredProject? {
        model.store?.projects.first { $0.id == projectID }
    }

    private var serviceNames: [String] {
        project?.services.map(\.name) ?? []
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameChanged: Bool {
        trimmedName != (project?.name ?? "")
    }

    /// Vero se qualche servizio del progetto è attualmente in esecuzione — usato per il
    /// messaggio d'avviso sotto il campo nome (un rename ferma i servizi in esecuzione, vedi
    /// `applyRename`).
    private var projectHasRunningServices: Bool {
        model.services.contains { $0.config.projectName == projectID && $0.processAlive }
    }

    private var infraPortValue: UInt16? {
        guard let port = UInt16(infraPortText.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else { return nil }
        return port
    }

    private var infraIsValid: Bool {
        guard showInfraCheck else { return true }
        return !infraLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && infraPortValue != nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && infraIsValid && project != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Impostazioni progetto")
                .font(.title2.weight(.semibold))

            nameSection
            colorSection
            infraSection
            profilesSection

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
        .frame(width: 480)
        .onAppear(perform: prefill)
    }

    // MARK: - Sezioni

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nome").font(.headline)
            TextField("Nome progetto", text: $name)
                .textFieldStyle(.roundedBorder)
            if trimmedName.isEmpty {
                Text("Il nome non può essere vuoto.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if nameChanged && projectHasRunningServices {
                Text("Rinominare fermerà i servizi in esecuzione del progetto")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colore").font(.headline)
            HStack(spacing: 10) {
                ForEach(ProjectAccentColor.presets) { preset in
                    colorDot(preset)
                }
            }
        }
    }

    private func colorDot(_ preset: ProjectAccentColor) -> some View {
        Button {
            accentColorHex = preset.hex
        } label: {
            Circle()
                .fill(preset.color)
                .frame(width: 22, height: 22)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: accentColorHex == preset.hex ? 2 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private var infraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Mostra spia infrastruttura", isOn: $showInfraCheck.animation(.snappy))
                .font(.headline)

            if showInfraCheck {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Etichetta").font(.caption).foregroundStyle(.secondary)
                        TextField("NATS", text: $infraLabel)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Porta").font(.caption).foregroundStyle(.secondary)
                        TextField("4222", text: $infraPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                }
                if infraPortValue == nil && !infraPortText.isEmpty {
                    Text("Porta non valida (1–65535).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profili di avvio").font(.headline)
                Spacer()
                Button {
                    profiles.append(EditableProfile(name: "", serviceNames: []))
                } label: {
                    Image(systemName: "plus")
                }
                .help("Aggiungi profilo")
            }

            if profiles.isEmpty {
                Text("Nessun profilo configurato.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach($profiles) { $profile in
                        profileRow($profile)
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: Binding<EditableProfile>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Nome profilo", text: profile.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    profiles.removeAll { $0.id == profile.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Elimina profilo")
            }

            // Chip di selezione servizi: toggle indipendenti, niente Menu — coerente con lo
            // stile "capsule" già usato altrove nell'app (vedi FocusView) e più leggibile di
            // un menu a tendina per liste corte di servizi per-progetto.
            if serviceNames.isEmpty {
                Text("Questo progetto non ha ancora backend.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(names: serviceNames, selected: profile.serviceNames)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    // MARK: - Prefill

    private func prefill() {
        guard let project else { return }
        name = project.name
        if let infraCheck = project.infraCheck {
            showInfraCheck = true
            infraLabel = infraCheck.label
            infraPortText = String(infraCheck.port)
        } else {
            showInfraCheck = false
            infraLabel = "NATS"
            infraPortText = ""
        }
        profiles = project.profiles.map { EditableProfile(name: $0.name, serviceNames: $0.serviceNames) }
        accentColorHex = project.accentColorHex
    }

    // MARK: - Salvataggio

    /// Applica, in ordine, rename (se cambiato) -> colore -> infra check -> profili. Si ferma
    /// al primo errore (mostrato inline) senza proseguire agli step successivi. Su successo
    /// completo, ricarica l'AppModel e chiude lo sheet.
    private func save() {
        guard let store = model.store else { return }
        var currentID = projectID

        if nameChanged {
            do {
                try applyRename(store: store, currentID: &currentID)
            } catch {
                saveError = error.localizedDescription
                return
            }
        }

        do {
            try store.updateProjectAccentColor(projectID: currentID, hex: accentColorHex)
        } catch {
            saveError = error.localizedDescription
            model.reloadFromStore()
            return
        }

        do {
            let infraCheck: StoredInfraCheck? = showInfraCheck
                ? StoredInfraCheck(label: infraLabel.trimmingCharacters(in: .whitespacesAndNewlines), port: infraPortValue ?? 0)
                : nil
            try store.updateInfraCheck(projectID: currentID, infraCheck: infraCheck)
        } catch {
            saveError = error.localizedDescription
            model.reloadFromStore()
            return
        }

        do {
            let storedProfiles = profiles.map {
                StoredProfile(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), serviceNames: $0.serviceNames)
            }
            try store.updateProfiles(projectID: currentID, profiles: storedProfiles)
        } catch {
            saveError = error.localizedDescription
            model.reloadFromStore()
            return
        }

        saveError = nil
        model.reloadFromStore()
        onDismiss()
    }

    /// Rinomina il progetto fermando PRIMA i servizi in esecuzione: un rename cambia
    /// `StoredProject.id`, e `reloadFromStore()` tratterebbe un id namespaced cambiato come
    /// "rimuovi il vecchio, aggiungi il nuovo" fermando silenziosamente un processo ancora
    /// vivo (vedi documentazione di `ServiceStore.renameProject`). Fermare esplicitamente
    /// prima del rename rende quell'arresto un effetto visibile e intenzionale, non un
    /// side-effect silenzioso del reload.
    private func applyRename(store: ServiceStore, currentID: inout String) throws {
        model.stopProject(named: currentID)
        try store.renameProject(id: currentID, to: trimmedName)
        currentID = trimmedName
    }
}

/// Stato locale editabile di un profilo — id stabile indipendente dal nome (che l'utente può
/// svuotare temporaneamente mentre digita) per non perdere l'identità della riga in `ForEach`.
private struct EditableProfile: Identifiable {
    let id = UUID()
    var name: String
    var serviceNames: [String]
}

/// Preset selezionabile nel color picker del progetto. `hex == nil` è il preset "grigio /
/// default" — nessun colore salvato, la card torna al glass neutro senza bordo accento.
private struct ProjectAccentColor: Identifiable {
    let name: String
    let hex: String?

    var id: String { hex ?? "default" }
    var color: Color { hex.flatMap(Color.init(hex:)) ?? Color.gray }

    static let presets: [ProjectAccentColor] = [
        ProjectAccentColor(name: "Blu", hex: "#4F8EF7"),
        ProjectAccentColor(name: "Verde", hex: "#34C759"),
        ProjectAccentColor(name: "Arancio", hex: "#FF9500"),
        ProjectAccentColor(name: "Rosso", hex: "#FF3B30"),
        ProjectAccentColor(name: "Viola", hex: "#AF52DE"),
        ProjectAccentColor(name: "Rosa", hex: "#FF2D55"),
        ProjectAccentColor(name: "Teal", hex: "#30B0C7"),
        ProjectAccentColor(name: "Grigio (default)", hex: nil),
    ]
}

/// Riga di chip "toggle" per la selezione multi di nomi servizio, disposti su più righe
/// (`FlowLayout` non disponibile prima di macOS 15 in questo target minimo dichiarato altrove
/// nel progetto: si usa una `LazyVGrid` adattiva, visivamente equivalente per liste corte).
private struct FlowChips: View {
    let names: [String]
    @Binding var selected: [String]

    private func isOn(_ name: String) -> Bool {
        selected.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func toggle(_ name: String) {
        if let index = selected.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button {
                    toggle(name)
                } label: {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOn(name) ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.18),
                                    in: .capsule)
                        .foregroundStyle(isOn(name) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
