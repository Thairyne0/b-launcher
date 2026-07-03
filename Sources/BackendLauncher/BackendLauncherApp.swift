import AppKit
import SwiftUI

/// Delegate: attivazione app da binario nudo (swift run) + conferma quit con backend attivi.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        CrashNotifier.requestAuthorizationIfNeeded()
        CrashNotifier.onNotificationTap = { [weak self] serviceID in
            NSApp.activate(ignoringOtherApps: true)
            self?.model?.revealService(named: serviceID)
        }
    }

    // Con la menu bar extra sempre presente, chiudere la finestra non deve terminare
    // l'app: i backend restano attivi e lo stato resta visibile dalla menu bar.
    // Cmd-Q continua a passare da applicationShouldTerminate con la conferma esistente.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.anyRunning else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Backend attivi"
        alert.informativeText = "Chiudendo il launcher tutti i backend verranno fermati. Continuare?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ferma tutto ed esci")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await model.shutdownForQuit()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BackendLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: ServiceStore
    @State private var model: AppModel

    init() {
        let store = ServiceStore()
        _store = State(initialValue: store)
        _model = State(initialValue: AppModel(store: store))
    }

    private var menuBarIcon: String {
        if model.services.contains(where: {
            if case .crashed = $0.status { return true }
            return false
        }) {
            return "exclamationmark.circle.fill"
        }
        if model.services.allSatisfy(\.processAlive) { return "circle.fill" }
        if model.services.contains(where: \.processAlive) { return "circle.lefthalf.filled" }
        return "circle"
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 860, height: 720)
        .commands {
            CommandMenu("Servizi") {
                // Etichetta statica: i contenuti di .commands non si ri-valutano
                // in modo affidabile al cambio di stato (limite SwiftUI documentato).
                Button("Espandi/comprimi tutti i terminali") {
                    model.toggleAllTerminals()
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                ForEach(Array(model.services.enumerated()), id: \.element.id) { index, service in
                    // scorciatoia solo per i primi 9: Character("10") crasherebbe
                    if index < 9 {
                        Button("Terminale \(service.config.displayName)") {
                            model.toggleTerminal(service.id)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button("Terminale \(service.config.displayName)") {
                            model.toggleTerminal(service.id)
                        }
                    }
                }

                Divider()

                Button("Avvia tutti") { model.startAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Riavvia tutti") { model.restartAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Ferma tutti…") { model.stopAllRequested = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: menuBarIcon)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Contenuto della menu bar extra: stato dei servizi + azioni globali + apri finestra.
struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.services) { service in
            Text("\(emoji(for: service.status)) \(service.config.displayName) — \(service.status.label)")
        }
        Divider()
        Button("Avvia tutti") { model.startAll() }
            .disabled(model.services.allSatisfy { $0.processAlive })
        Button("Riavvia tutti") { model.restartAll() }
            .disabled(!model.anyRunning)
        Button("Ferma tutti") { model.stopAll() }
            .disabled(!model.anyRunning)
            .help("Ferma subito, senza conferma")
        Divider()
        Button("Apri launcher") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }

    private func emoji(for status: ServiceStatus) -> String {
        switch status {
        case .stopped: return "⚪️"
        case .starting: return "🟡"
        case .running: return "🟢"
        case .stopping: return "🟠"
        case .crashed: return "🔴"
        case .external: return "🔵"
        }
    }
}
