import SwiftUI

/// Pagina attiva della finestra principale, persistita tra i lanci dell'app.
enum LauncherPage: String, CaseIterable {
    case dashboard = "Backend"
    case focus = "Focus"
}

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("launcherPage") private var page: LauncherPage = .dashboard

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case .dashboard:
                    ScrollView {
                        GlassEffectContainer(spacing: 14) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 470, maximum: .infinity), spacing: 16)],
                                      spacing: 20) {
                                ForEach(model.services) { controller in
                                    ServiceCardView(controller: controller)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: 1150)
                        }
                        .frame(maxWidth: .infinity)
                    }
                case .focus:
                    FocusView(model: model)
                }
            }
            .background {
                LinearGradient(colors: [Color(hue: 0.62, saturation: 0.30, brightness: 0.16),
                                        Color(hue: 0.68, saturation: 0.28, brightness: 0.09)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
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
