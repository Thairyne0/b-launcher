import SwiftUI

/// Pagina attiva della finestra principale, persistita tra i lanci dell'app.
enum LauncherPage: String, CaseIterable {
    case dashboard = "Backend"
    case focus = "Focus"
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("launcherPage") private var page: LauncherPage = .dashboard
    @State private var contentWidth: CGFloat = 1200

    private var gridColumns: [GridItem] {
        contentWidth < 860
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 16), GridItem(.flexible())]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .dashboard:
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
                    .transition(.opacity)
                case .focus:
                    FocusView(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: page)
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
                ToolbarItem(placement: .principal) {
                    Picker("Pagina", selection: $page) {
                        ForEach(LauncherPage.allCases, id: \.self) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .labelsHidden()
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(model.allExpanded ? "Comprimi tutti" : "Espandi tutti",
                           systemImage: model.allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        withAnimation(.snappy) {
                            model.toggleAllTerminals()
                        }
                    }
                    Menu("Profili", systemImage: "list.bullet.rectangle") {
                        ForEach(ServiceConfig.profiles) { profile in
                            Button(profile.name) { model.start(profile: profile) }
                        }
                    }
                    Button("Avvia tutti", systemImage: "play.fill") { model.startAll() }
                        .disabled(model.services.allSatisfy { $0.processAlive })
                    Button("Ferma tutti", systemImage: "stop.fill") { model.stopAllRequested = true }
                        .disabled(!model.anyRunning)
                }
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
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
