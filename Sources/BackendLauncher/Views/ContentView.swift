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
    @State private var expandedServices: Set<String> = []
    @State private var contentWidth: CGFloat = 1200

    private var allExpanded: Bool { expandedServices.count == model.services.count }

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
                                        get: { expandedServices.contains(controller.id) },
                                        set: { isOn in
                                            if isOn { expandedServices.insert(controller.id) } else { expandedServices.remove(controller.id) }
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
                case .focus:
                    FocusView(model: model)
                }
            }
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
                    Button(allExpanded ? "Comprimi tutti" : "Espandi tutti",
                           systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                        withAnimation(.snappy) {
                            expandedServices = allExpanded ? [] : Set(model.services.map(\.id))
                        }
                    }
                    Menu("Profili", systemImage: "list.bullet.rectangle") {
                        ForEach(ServiceConfig.profiles) { profile in
                            Button(profile.name) { model.start(profile: profile) }
                        }
                    }
                    Button("Avvia tutti", systemImage: "play.fill") { model.startAll() }
                        .disabled(model.services.allSatisfy { $0.processAlive })
                    Button("Ferma tutti", systemImage: "stop.fill") { model.stopAll() }
                        .disabled(!model.anyRunning)
                }
            }
            .alert("NATS non raggiungibile", isPresented: $model.showNATSWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("La porta 4222 è chiusa: i backend partono ma non comunicano tra loro. Controlla i container Docker (skillera-nats).")
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
