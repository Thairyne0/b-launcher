import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("sidebarSelection") private var selectionRaw = "grid"
    @State private var contentWidth: CGFloat = 1200
    /// Progetto per cui è stato richiesto un cambio di cartella radice dal banner "cartelle
    /// mancanti" — pilota il `.fileImporter` di rebase, stessa meccanica del menu contestuale
    /// in `SidebarView` ma di competenza di questa vista perché il banner vive nel dettaglio.
    @State private var rebasingProjectID: String?
    @State private var rebaseError: String?
    /// Progetto per cui è stata richiesta l'aggiunta del primo backend dallo stato vuoto
    /// (`emptyProjectView`) — pilota una sheet di competenza di questa vista, indipendente da
    /// quella (analoga) ospitata da `SidebarView` per il resto dei flussi add/edit.
    @State private var addingServiceToProjectID: String?
    /// `true` finché l'utente non ha mai chiuso la sheet di benvenuto — persistito così la
    /// sheet appare una volta sola nella vita dell'installazione, non a ogni avvio dell'app.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcomeSheet = false
    @State private var paletteState = PaletteState.shared
    /// Esito di una scansione cartella (bottone sidebar "Scansiona cartella…" o drag&drop di
    /// una directory) in attesa di conferma utente. Wrapped in un tipo `Identifiable` per
    /// pilotare `.sheet(item:)`: vive qui (non in `SidebarView`) perché entrambi i trigger
    /// (sidebar e drop sull'intera finestra) devono condividere la stessa presentazione.
    @State private var pendingScan: PendingScan?
    /// File `.json` sganciato sulla finestra: precarica `ImportTemplateSheet` con questo path
    /// invece di aprirla vuota — riusa lo stesso sheet del bottone "Importa progetto…" della
    /// sidebar (quel percorso resta invariato, con `preloadedFileURL` a `nil`).
    @State private var droppedTemplateURL: URL?
    @State private var showImportSheetFromDrop = false
    /// Import in sospeso da un deep link `blauncher://import?file=...&root=...` (tipicamente
    /// il comando "un click" suggerito da `ClaudeCodePrompt` a fine analisi). Osserva
    /// `DeepLinkCenter.shared` così una `open "blauncher://..."` mentre l'app è già in
    /// esecuzione riusa la stessa finestra invece di aprirne una nuova.
    @State private var deepLinkCenter = DeepLinkCenter.shared
    /// `true` mentre un drag di file è sopra la finestra — pilota l'overlay "Rilascia per
    /// aggiungere".
    @State private var dropTargeted = false

    private var gridColumns: [GridItem] {
        contentWidth < 860
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 16), GridItem(.flexible())]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model, selection: Binding(
                get: { SidebarSelectionCoding.decode(selectionRaw) },
                set: { selectionRaw = SidebarSelectionCoding.encode($0) }
            ), onScanRequested: { result, root in
                pendingScan = PendingScan(result: result, root: root)
            })
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detailContent
        }
        .overlay(alignment: .bottom) { ToastOverlay() }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.accentColor.opacity(0.08))
                    }
                    .overlay {
                        Label("Rilascia per aggiungere", systemImage: "square.and.arrow.down.on.square")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if paletteState.isPresented {
                CommandPaletteView(
                    items: paletteItems,
                    onSelect: handlePaletteSelection,
                    onDismiss: { paletteState.isPresented = false }
                )
            }
        }
        .onAppear {
            if !hasSeenWelcome {
                showWelcomeSheet = true
            }
        }
        .sheet(isPresented: $showWelcomeSheet, onDismiss: { hasSeenWelcome = true }) {
            WelcomeView {
                showWelcomeSheet = false
            }
        }
        .alert("NATS non raggiungibile", isPresented: $model.showNATSWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("La porta 4222 è chiusa: i backend partono ma non comunicano tra loro. Controlla i container Docker (skillera-nats).")
        }
        .confirmationDialog("Fermare tutti i backend?", isPresented: $model.stopAllRequested) {
            Button("Ferma tutti", role: .destructive) {
                model.stopAll()
                ToastCenter.shared.show("Arresto di tutti i servizi", systemImage: "stop.circle.fill")
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Tutti i processi verranno terminati.")
        }
        // Deep-link da notifica di crash: naviga direttamente sul pannello dedicato del
        // servizio rivelato da AppModel.revealService (expandedServices è già stato
        // aggiornato lì, per coerenza con la griglia se l'utente torna indietro).
        // Fallback alla griglia se per qualche motivo l'id non è disponibile.
        .onChange(of: model.revealRequestCount) { _, _ in
            if let id = model.lastRevealedServiceID {
                selectionRaw = SidebarSelectionCoding.encode(.service(id))
            } else {
                selectionRaw = SidebarSelectionCoding.encode(.grid)
            }
        }
        .fileImporter(isPresented: Binding(
            get: { rebasingProjectID != nil },
            set: { if !$0 { rebasingProjectID = nil } }
        ), allowedContentTypes: [.folder]) { result in
            handleRebasePick(result)
        }
        .sheet(item: Binding(
            get: { addingServiceToProjectID.map(EmptyProjectSheetTarget.init) },
            set: { addingServiceToProjectID = $0?.id }
        )) { target in
            ServiceFormSheet(model: model, projectID: target.id, mode: .add) {
                addingServiceToProjectID = nil
            }
        }
        .sheet(item: $pendingScan) { pending in
            ScanResultsSheet(model: model, scanResult: pending.result, root: pending.root, onDismiss: {
                pendingScan = nil
            }, onCreated: { projectID in
                selectionRaw = SidebarSelectionCoding.encode(.project(projectID))
            })
        }
        .sheet(isPresented: $showImportSheetFromDrop, onDismiss: { droppedTemplateURL = nil }) {
            ImportTemplateSheet(model: model, onDismiss: {
                showImportSheetFromDrop = false
            }, preloadedFileURL: droppedTemplateURL)
        }
        .sheet(item: Binding(
            get: { deepLinkCenter.pendingImport.map(PendingDeepImportTarget.init) },
            set: { if $0 == nil { deepLinkCenter.pendingImport = nil } }
        )) { target in
            ImportTemplateSheet(model: model, onDismiss: {
                deepLinkCenter.pendingImport = nil
            }, preloadedFileURL: target.fileURL, preloadedRootURL: target.rootURL)
        }
        .alert("Impossibile cambiare cartella", isPresented: Binding(
            get: { rebaseError != nil },
            set: { if !$0 { rebaseError = nil } }
        )) {
            Button("OK", role: .cancel) { rebaseError = nil }
        } message: {
            Text(rebaseError ?? "")
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var detailContent: some View {
        let currentSelection = SidebarSelectionCoding.decode(selectionRaw)

        Group {
            switch currentSelection {
            case .grid:
                gridView(services: model.services)
                    .transition(.opacity)
            case .focus:
                FocusView(model: model)
                    .transition(.opacity)
            case .service(let id):
                if let controller = model.services.first(where: { $0.id == id }) {
                    ServicePaneView(controller: controller)
                        .padding(20)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    ContentUnavailableView("Servizio non trovato", systemImage: "questionmark.square.dashed")
                }
            case .project(let id):
                let projectServices = model.services.filter { $0.config.projectName == id }
                if projectServices.isEmpty {
                    if model.store?.projects.contains(where: { $0.id == id }) == true {
                        emptyProjectView(projectID: id)
                    } else {
                        ContentUnavailableView("Progetto non trovato", systemImage: "questionmark.folder")
                    }
                } else {
                    VStack(spacing: 14) {
                        if allWorkingDirectoriesMissing(projectServices) {
                            missingRootBanner(projectID: id)
                        }
                        if model.templateSyncAvailable.contains(id) {
                            templateSyncBanner(projectID: id)
                        }
                        gridView(services: projectServices)
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: currentSelection)
        .background {
            LinearGradient(colors: colorScheme == .dark
                           ? [Color(white: 0.13), Color(white: 0.07)]
                           : [Color(white: 0.94), Color(white: 0.86)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        }
        .navigationTitle(navigationTitle(for: currentSelection))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NATSIndicator(up: model.natsUp)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isGridLike(currentSelection) {
                    Button(model.allExpanded ? "Comprimi tutti" : "Espandi tutti",
                           systemImage: model.allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        withAnimation(.snappy) {
                            model.toggleAllTerminals()
                        }
                    }
                    .help(model.allExpanded ? "Comprimi tutti (⌘E)" : "Espandi tutti (⌘E)")
                }
                profilesMenu
                Button("Avvia tutti", systemImage: "play.fill") {
                    let startingCount = model.services.filter { !$0.processAlive }.count
                    model.startAll()
                    ToastCenter.shared.show("Avvio di \(startingCount) servizi…", systemImage: "play.circle.fill")
                }
                    .disabled(model.services.allSatisfy { $0.processAlive })
                    .help("Avvia tutti (⌘⇧A)")
                Button("Riavvia", systemImage: "arrow.clockwise") {
                    if case .project(let id) = currentSelection {
                        model.restartProject(named: id)
                    } else {
                        model.restartAll()
                    }
                    ToastCenter.shared.show("Riavvio in corso", systemImage: "arrow.clockwise")
                }
                .disabled(!model.anyRunning)
                .help("Riavvia (⌘⇧R)")
                Button("Ferma tutti", systemImage: "stop.fill") { model.stopAllRequested = true }
                    .disabled(!model.anyRunning)
                    .help("Ferma tutti (⌘⇧S)")
                if case .project(let id) = currentSelection {
                    Button("Pulisci terminali", systemImage: "clear") {
                        model.clearProjectTerminals(named: id)
                        ToastCenter.shared.show("Terminali puliti", systemImage: "clear")
                    }
                    .help("Pulisci tutti i terminali del progetto")
                }
            }
        }
    }

    /// Titolo di navigazione per selezione: nome progetto per `.project`, invariato altrove.
    private func navigationTitle(for selection: SidebarSelection) -> String {
        switch selection {
        case .project(let id):
            return model.store?.projects.first(where: { $0.id == id })?.name ?? id
        default:
            return "Skillera Backend"
        }
    }

    /// "Espandi/comprimi tutti" ha senso su qualunque vista a griglia, sia `.grid` che `.project`.
    private func isGridLike(_ selection: SidebarSelection) -> Bool {
        switch selection {
        case .grid, .project: return true
        default: return false
        }
    }

    /// Menu "Profili": submenu per progetto quando ce n'è più di uno (i profili sono
    /// definiti per-progetto e i nomi dei servizi possono ripetersi tra progetti diversi),
    /// piatto come prima quando c'è un solo progetto (o nell'init legacy senza store).
    @ViewBuilder
    private var profilesMenu: some View {
        let groups = model.projectProfiles.filter { !$0.profiles.isEmpty }
        if groups.count > 1 {
            Menu("Profili", systemImage: "list.bullet.rectangle") {
                ForEach(groups, id: \.projectName) { group in
                    Menu(group.projectName) {
                        ForEach(group.profiles) { profile in
                            Button(profile.name) { model.start(profile: profile, inProject: group.projectName) }
                        }
                    }
                }
            }
        } else {
            Menu("Profili", systemImage: "list.bullet.rectangle") {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.start(profile: profile) }
                }
            }
        }
    }

    private func gridView(services: [ServiceController]) -> some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: gridColumns, spacing: 20) {
                    ForEach(services) { controller in
                        ServiceCardView(controller: controller, showTerminal: Binding(
                            get: { model.expandedServices.contains(controller.id) },
                            set: { isOn in
                                if isOn { model.expandedServices.insert(controller.id) } else { model.expandedServices.remove(controller.id) }
                            }
                        ))
                    }
                }
                .padding(20)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            contentWidth = newWidth
        }
    }

    /// Vero se `services` non è vuoto e NESSUNA working directory esiste su disco — segnale
    /// che l'intero progetto è stato spostato/clonato su un Mac diverso e la root va
    /// riconfigurata. Pura funzione dei controller (nessuna dipendenza da `self`) così è
    /// testabile in isolamento.
    private func allWorkingDirectoriesMissing(_ services: [ServiceController]) -> Bool {
        !services.isEmpty && services.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.config.workingDirectory.path)
        }
    }

    /// Stato vuoto per un progetto esistente ma senza backend configurati (distinto da
    /// "progetto non trovato": qui l'id esiste in `model.store.projects`, semplicemente
    /// `services` è vuoto). Offre direttamente l'azione per aggiungere il primo backend
    /// invece di rimandare l'utente alla sidebar.
    private func emptyProjectView(projectID: String) -> some View {
        ContentUnavailableView {
            Label("Nessun backend", systemImage: "shippingbox")
        } description: {
            Text("Aggiungi il primo backend di questo progetto.")
        } actions: {
            Button("Aggiungi backend…") {
                addingServiceToProjectID = projectID
            }
        }
    }

    /// Banner "cartelle mancanti", mostrato solo nel dettaglio filtrato su UN progetto
    /// (`.project(id)`): in `.grid` la vista mescola servizi di progetti diversi, quindi un
    /// singolo banner "cambia cartella" non avrebbe un progetto univoco a cui applicarsi —
    /// mostrarlo lì avrebbe richiesto o un banner per progetto (rumoroso, la griglia "tutti" è
    /// vista come cruscotto d'insieme non di configurazione) o nascondere quale progetto è
    /// interessato (ambiguo). Si preferisce la versione semplice e inequivocabile: solo in
    /// `.project`, dove il banner ha esattamente un target.
    private func missingRootBanner(projectID: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            Text("Le cartelle di questo progetto non esistono su questo Mac.")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Cambia cartella radice…") {
                rebasingProjectID = projectID
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// Banner "template del team cambiato", mostrato in `.project(id)` quando
    /// `model.templateSyncAvailable` contiene l'id — il file `.blauncher.json` da cui il
    /// progetto è stato importato è cambiato sul disco (tipicamente dopo un `git pull` che ha
    /// portato una revisione aggiornata committata da un collega). "Sincronizza" rilegge il file
    /// e sostituisce servizi/profili/infraCheck del progetto, preservando nome e colore accento
    /// (stessa semantica di `ServiceStore.syncProjectFromTemplate`); i servizi in esecuzione con
    /// una config cambiata NON vengono fermati (stesso meccanismo di `pendingConfigChanges`
    /// già usato da ogni altra mutazione dello store che tocca `services`).
    private func templateSyncBanner(projectID: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .imageScale(.large)
            Text("Il template del progetto è cambiato.")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Sincronizza") {
                syncProjectFromTemplate(projectID: projectID)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.tint(.blue.opacity(0.25)), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// Azione del bottone "Sincronizza" del banner di template sync: rilegge il file tracciato,
    /// ricarica lo store e conferma con un toast. Un fallimento (es. file rimosso proprio tra il
    /// rilevamento del banner e il click) mostra un toast d'errore invece di un alert — coerente
    /// con l'uso di `ToastCenter` per conferme/errori di azioni "fire and forget" in questa vista.
    private func syncProjectFromTemplate(projectID: String) {
        guard let store = model.store else { return }
        do {
            try store.syncProjectFromTemplate(projectID: projectID)
            model.reloadFromStore()
            ToastCenter.shared.show("Progetto sincronizzato", systemImage: "checkmark.circle.fill")
        } catch {
            ToastCenter.shared.show(error.localizedDescription, systemImage: "xmark.octagon.fill")
        }
    }

    // MARK: - Palette comandi (⌘K)

    /// Prefissi degli `id` di `PaletteItem` usati per instradare la selezione in
    /// `handlePaletteSelection`: la palette stessa (`CommandPaletteView`) non conosce il
    /// significato degli id, solo `ContentView` (che ha accesso al model) sa cosa eseguire.
    private enum PaletteIDs {
        static let goToGrid = "goto:grid"
        static let goToFocus = "goto:focus"
        static let openHelp = "action:open-help"
        static let startAll = "action:start-all"
        static let stopAll = "action:stop-all"
        static let restartAll = "action:restart-all"
        static let toggleTerminals = "action:toggle-terminals"
        static let serviceGoto = "goto:service:"
        static let serviceRestart = "action:restart-service:"
        static let projectStart = "action:start-project:"
    }

    /// Elenco degli item della palette, ricostruito a ogni apertura (`CommandPaletteView` lo
    /// riceve come snapshot): navigazione verso griglia/Focus/singolo servizio, riavvio dei
    /// singoli servizi attivi, azioni globali (avvia/ferma/riavvia tutti, espandi/comprimi
    /// terminali), apri Aiuto, e avvio rapido per progetto. Le Impostazioni sono
    /// intenzionalmente escluse: `SettingsLink` non è invocabile in modo programmatico da qui.
    private var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: PaletteIDs.goToGrid, title: "Vai a Griglia", subtitle: nil, systemImage: "square.grid.2x2"),
            PaletteItem(id: PaletteIDs.goToFocus, title: "Vai a Focus", subtitle: nil, systemImage: "rectangle.on.rectangle"),
        ]

        for controller in model.services {
            items.append(PaletteItem(
                id: PaletteIDs.serviceGoto + controller.id,
                title: "Vai a \(controller.config.displayName)",
                subtitle: controller.config.projectName.isEmpty ? nil : controller.config.projectName,
                systemImage: controller.config.symbolName ?? "server.rack"
            ))
            if controller.processAlive {
                items.append(PaletteItem(
                    id: PaletteIDs.serviceRestart + controller.id,
                    title: "Riavvia \(controller.config.displayName)",
                    subtitle: controller.config.projectName.isEmpty ? nil : controller.config.projectName,
                    systemImage: "arrow.clockwise"
                ))
            }
        }

        items.append(contentsOf: [
            PaletteItem(id: PaletteIDs.startAll, title: "Avvia tutti", subtitle: nil, systemImage: "play.fill"),
            PaletteItem(id: PaletteIDs.stopAll, title: "Ferma tutti", subtitle: nil, systemImage: "stop.fill"),
            PaletteItem(id: PaletteIDs.restartAll, title: "Riavvia tutti", subtitle: nil, systemImage: "arrow.clockwise"),
            PaletteItem(id: PaletteIDs.toggleTerminals, title: "Espandi/comprimi tutti i terminali", subtitle: nil, systemImage: "rectangle.expand.vertical"),
            PaletteItem(id: PaletteIDs.openHelp, title: "Apri Aiuto", subtitle: nil, systemImage: "questionmark.circle"),
        ])

        if let projects = model.store?.projects {
            for project in projects {
                items.append(PaletteItem(
                    id: PaletteIDs.projectStart + project.id,
                    title: "Avvia progetto \(project.name)",
                    subtitle: nil,
                    systemImage: "folder"
                ))
            }
        }

        return items
    }

    /// Esegue l'azione codificata nell'id dell'item selezionato dalla palette. La navigazione
    /// (`goto:*`) aggiorna `selectionRaw` come farebbe un click in sidebar; le azioni globali
    /// richiamano gli stessi metodi di `AppModel` usati dalla toolbar, con lo stesso toast di
    /// conferma dove la toolbar già lo mostra.
    private func handlePaletteSelection(_ item: PaletteItem) {
        switch item.id {
        case PaletteIDs.goToGrid:
            selectionRaw = SidebarSelectionCoding.encode(.grid)
        case PaletteIDs.goToFocus:
            selectionRaw = SidebarSelectionCoding.encode(.focus)
        case PaletteIDs.openHelp:
            openWindow(id: "help")
        case PaletteIDs.startAll:
            let startingCount = model.services.filter { !$0.processAlive }.count
            model.startAll()
            ToastCenter.shared.show("Avvio di \(startingCount) servizi…", systemImage: "play.circle.fill")
        case PaletteIDs.stopAll:
            model.stopAllRequested = true
        case PaletteIDs.restartAll:
            model.restartAll()
            ToastCenter.shared.show("Riavvio in corso", systemImage: "arrow.clockwise")
        case PaletteIDs.toggleTerminals:
            withAnimation(.snappy) { model.toggleAllTerminals() }
        default:
            if let id = item.id.dropPrefix(PaletteIDs.serviceGoto) {
                selectionRaw = SidebarSelectionCoding.encode(.service(id))
            } else if let id = item.id.dropPrefix(PaletteIDs.serviceRestart) {
                if let controller = model.services.first(where: { $0.id == id }) {
                    controller.restart()
                    ToastCenter.shared.show("Riavvio \(controller.config.displayName)", systemImage: "arrow.clockwise")
                }
            } else if let id = item.id.dropPrefix(PaletteIDs.projectStart) {
                model.startProject(named: id)
                let projectName = model.store?.projects.first(where: { $0.id == id })?.name ?? id
                ToastCenter.shared.show("Avvio progetto \(projectName)", systemImage: "play.circle.fill")
            }
        }
    }

    /// Esito del `.fileImporter` del banner "cartelle mancanti": ribasa il progetto scelto
    /// sulla nuova root. Stessa semantica del rebase nel menu contestuale della sidebar
    /// (`SidebarView.handleRebasePick`), duplicata qui perché il banner vive nel dettaglio e
    /// non ha accesso allo stato privato della sidebar.
    private func handleRebasePick(_ result: Result<URL, Error>) {
        guard let projectID = rebasingProjectID else { return }
        rebasingProjectID = nil
        guard let store = model.store else { return }
        switch result {
        case .failure(let error):
            rebaseError = error.localizedDescription
        case .success(let url):
            do {
                try store.rebaseProject(id: projectID, ontoRoot: url)
                model.reloadFromStore()
                ToastCenter.shared.show("Percorsi aggiornati", systemImage: "checkmark.circle.fill")
            } catch {
                rebaseError = error.localizedDescription
            }
        }
    }

    // MARK: - Drag & drop (cartella progetto o template .json)

    /// Gestisce un drop di file sulla finestra: carica il PRIMO item come `URL` (più item
    /// trascinati insieme non sono un caso d'uso previsto — si ignora tutto tranne il primo,
    /// stessa semantica "un solo target" delle altre picker dell'app). Una directory avvia la
    /// scansione (`ProjectScanner`) e presenta `ScanResultsSheet`; un file che finisce per
    /// ".json" precarica `ImportTemplateSheet`. Qualunque altro tipo di file viene ignorato
    /// silenziosamente (nessun formato noto da importare).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                handleDroppedURL(url)
            }
        }
        return true
    }

    private func handleDroppedURL(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            let result = ProjectScanner.scan(root: url)
            pendingScan = PendingScan(result: result, root: url)
        } else if url.pathExtension.lowercased() == "json" {
            droppedTemplateURL = url
            showImportSheetFromDrop = true
        }
    }
}

/// Wrapper `Identifiable` per pilotare `.sheet(item:)` con un `String?` opzionale (project id) —
/// analogo a `SheetProjectID` in `SidebarView.swift`, duplicato qui perché quello è `private`
/// al file e questa sheet è di competenza esclusiva di `ContentView` (stato vuoto progetto).
private struct EmptyProjectSheetTarget: Identifiable {
    let id: String
}

/// Esito di una scansione cartella in attesa di conferma (bottone sidebar o drag&drop di una
/// directory), con un id stabile per `.sheet(item:)` — la root scelta dall'utente è univoca per
/// singola richiesta di scan, quindi ne deriva l'identità.
private struct PendingScan: Identifiable {
    let result: ProjectScanner.ScanResult
    let root: URL
    var id: String { root.path }
}

/// Wrapper `Identifiable` per pilotare `.sheet(item:)` da `DeepLinkCenter.shared.pendingImport`
/// (uno `struct` non-`Identifiable`, condiviso con `DeepLinkCenter` per restare indipendente da
/// SwiftUI): l'id è il path del file, univoco per singola richiesta di import via deep link.
private struct PendingDeepImportTarget: Identifiable {
    let fileURL: URL
    let rootURL: URL?
    var id: String { fileURL.path }

    init(_ pending: PendingDeepImport) {
        fileURL = pending.fileURL
        rootURL = pending.rootURL
    }
}

private extension String {
    /// `nil` se `self` non inizia per `prefix`, altrimenti il resto della stringa dopo il
    /// prefisso — usato per decodificare gli id "namespaced" della palette comandi
    /// (`ContentView.PaletteIDs`) senza dover ricorrere a `dropFirst(prefix.count)` "a occhio"
    /// in ogni call site.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
