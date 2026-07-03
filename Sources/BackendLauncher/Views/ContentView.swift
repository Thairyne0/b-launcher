import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("sidebarSelection") private var selectionRaw = "grid"
    @State private var contentWidth: CGFloat = 1200

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
            ))
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detailContent
        }
        .alert("NATS non raggiungibile", isPresented: $model.showNATSWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("La porta 4222 è chiusa: i backend partono ma non comunicano tra loro. Controlla i container Docker (skillera-nats).")
        }
        .confirmationDialog("Fermare tutti i backend?", isPresented: $model.stopAllRequested) {
            Button("Ferma tutti", role: .destructive) { model.stopAll() }
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
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var detailContent: some View {
        let currentSelection = SidebarSelectionCoding.decode(selectionRaw)

        Group {
            switch currentSelection {
            case .grid:
                gridView
                    .transition(.opacity)
            case .focus:
                FocusView(model: model)
                    .transition(.opacity)
            case .service(let id):
                if let controller = model.services.first(where: { $0.id == id }) {
                    ServicePaneView(controller: controller)
                        .padding(20)
                        .transition(.opacity)
                } else {
                    ContentUnavailableView("Servizio non trovato", systemImage: "questionmark.square.dashed")
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: currentSelection)
        .background {
            LinearGradient(colors: colorScheme == .dark
                           ? [Color(white: 0.13), Color(white: 0.07)]
                           : [Color(white: 0.96), Color(white: 0.90)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        }
        .navigationTitle("Skillera Backend")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                NATSIndicator(up: model.natsUp)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if currentSelection == .grid {
                    Button(model.allExpanded ? "Comprimi tutti" : "Espandi tutti",
                           systemImage: model.allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        withAnimation(.snappy) {
                            model.toggleAllTerminals()
                        }
                    }
                }
                profilesMenu
                Button("Avvia tutti", systemImage: "play.fill") { model.startAll() }
                    .disabled(model.services.allSatisfy { $0.processAlive })
                Button("Ferma tutti", systemImage: "stop.fill") { model.stopAllRequested = true }
                    .disabled(!model.anyRunning)
            }
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

    private var gridView: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                LazyVGrid(columns: gridColumns, spacing: 20) {
                    ForEach(model.services) { controller in
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
}
