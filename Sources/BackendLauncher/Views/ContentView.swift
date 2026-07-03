import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(model.services) { controller in
                            ServiceCardView(controller: controller)
                        }
                    }
                    .padding(20)
                }
            }
            .background {
                LinearGradient(colors: [Color(hue: 0.61, saturation: 0.35, brightness: 0.28),
                                        Color(hue: 0.68, saturation: 0.30, brightness: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            }
            .navigationTitle("Skillera Backend")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    NATSIndicator(up: model.natsUp)
                }
                ToolbarItemGroup(placement: .primaryAction) {
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
