import AppKit
import SwiftUI

/// Richiesta di import in sospeso, generata da un deep link `blauncher://import` — presentata
/// da `ContentView` tramite `ImportTemplateSheet` (stessa sheet del bottone "Importa
/// progetto…" e del drag&drop, precaricata sia sul file sia, se presente, sulla root).
struct PendingDeepImport: Equatable {
    var fileURL: URL
    var rootURL: URL?
}

/// Gestisce i deep link `blauncher://` (attualmente il solo `import`). Isolato dalla UI così è
/// testabile senza `NSApp`/scene: `handle(url:)` è pura salvo l'accesso al filesystem per
/// validare che il file indicato esista davvero.
///
/// Formato supportato: `blauncher://import?file=/percorso/assoluto/progetto.blauncher.json`
/// con `root` opzionale (`&root=/percorso/assoluto/repo`) per precompilare anche la cartella di
/// destinazione — pensato per il comando "un click" che `ClaudeCodePrompt` chiede all'AI di
/// stampare a fine analisi (`open "blauncher://import?file=...&root=..."`).
@MainActor
@Observable
final class DeepLinkCenter {
    static let shared = DeepLinkCenter()

    /// Import in attesa di conferma utente: la view lo consuma presentando `ImportTemplateSheet`
    /// e lo azzera alla chiusura (sheet dismissed) per non ripresentarlo su una successiva
    /// ricomparsa della scena.
    var pendingImport: PendingDeepImport?

    /// Init non-privato: la UI usa sempre `.shared`, i test vogliono un'istanza isolata (stesso
    /// pattern di `ToastCenter`).
    init() {}

    func handle(url: URL) {
        guard url.scheme == "blauncher" else { return }
        guard url.host == "import" else {
            ToastCenter.shared.show("Link non valido", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // `URLComponents.queryItems` decodifica automaticamente il percent-encoding.
        let queryItems = components?.queryItems ?? []
        guard let fileParam = queryItems.first(where: { $0.name == "file" })?.value, !fileParam.isEmpty else {
            ToastCenter.shared.show("Link non valido", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let fileURL = URL(fileURLWithPath: fileParam)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, fileURL.pathExtension.lowercased() == "json" else {
            ToastCenter.shared.show("Link non valido", systemImage: "exclamationmark.triangle.fill")
            return
        }
        let rootParam = queryItems.first(where: { $0.name == "root" })?.value
        let rootURL = rootParam.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        pendingImport = PendingDeepImport(fileURL: fileURL, rootURL: rootURL)
    }
}

/// Delegate: attivazione app da binario nudo (swift run) + conferma quit con backend attivi.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppSettings.applyAppearance()
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
                .onOpenURL { url in
                    DeepLinkCenter.shared.handle(url: url)
                }
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

            CommandMenu("Vista") {
                // ⌘+ arriva come tasto "=" (senza shift) sui layout US: si mappa "=" così
                // la scorciatoia scatta senza dover premere anche Shift.
                Button("Aumenta testo terminale") {
                    AppSettings.terminalFontSize += 1
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Riduci testo terminale") {
                    AppSettings.terminalFontSize -= 1
                }
                .keyboardShortcut("-", modifiers: .command)
            }

            // `CommandGroup` non può leggere `@Environment` direttamente (non è una View):
            // si incapsula l'azione in una piccola View (`HelpCommand`) che la legge e la
            // usa nel proprio `Button`. Pattern documentato per aprire finestre da .commands.
            CommandGroup(replacing: .help) {
                HelpCommand()
            }

            // Sostituisce la voce di default "Informazioni su <App>" del menu app con una che
            // apre la nostra `Window(id: "about")` — stesso pattern-wrapper di `HelpCommand`.
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Button("Apri palette comandi") {
                    PaletteState.shared.isPresented = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // Unica voce del Menu sidebar "Aggiungi progetto" promossa a comando globale
            // (⇧⌘G, attivo ovunque, non solo a menu aperto): l'azione è stateless — copia
            // negli appunti + toast — a differenza delle altre tre (nuovo/scansiona/importa),
            // che aprono alert/sheet il cui stato vive in `SidebarView` e non è raggiungibile
            // da qui senza un refactor più ampio (vedi report).
            CommandGroup(after: .newItem) {
                Divider()
                Button("Genera con Claude Code…") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ClaudeCodePrompt.make(), forType: .string)
                    ToastCenter.shared.show("Prompt copiato", systemImage: "checkmark")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
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

        Window("Aiuto — Backend Launcher", id: "help") {
            HelpView()
        }
        .defaultSize(width: 780, height: 560)

        Window("Informazioni su Backend Launcher", id: "about") {
            AboutView()
        }
        .defaultSize(width: 360, height: 420)
        .windowResizability(.contentSize)
    }
}

/// Voce di menu "Aiuto Backend Launcher" (sostituisce il menu Aiuto di sistema): apre la
/// finestra di aiuto (`id: "help"`). Isolata in una View perché `CommandGroup` non ha accesso
/// a `@Environment(\.openWindow)` — solo le View lo hanno.
private struct HelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Aiuto Backend Launcher") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}

/// Voce di menu "Informazioni su Backend Launcher" (sostituisce la voce standard del menu app):
/// apre la finestra `id: "about"`. Stesso motivo-wrapper di `HelpCommand`: `CommandGroup` non
/// ha accesso a `@Environment(\.openWindow)`, solo le View lo hanno.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Informazioni su Backend Launcher") {
            openWindow(id: "about")
        }
    }
}

/// Contenuto della menu bar extra: stato dei servizi + azioni globali + apri finestra.
struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Servizi raggruppati per progetto: un submenu per progetto (con avvia/ferma solo
        // di quel progetto) quando il progetto ha un nome; lista piatta per il caso legacy
        // senza progetti (projectName vuoto).
        ForEach(model.servicesByProject, id: \.projectName) { group in
            if group.projectName.isEmpty {
                ForEach(group.services) { service in
                    Text("\(emoji(for: service.status)) \(service.config.displayName) — \(service.status.label)")
                }
            } else {
                Menu("\(projectEmoji(group.services)) \(group.projectName)") {
                    ForEach(group.services) { service in
                        Text("\(emoji(for: service.status)) \(service.config.displayName) — \(service.status.label)")
                    }
                    Divider()
                    Button("Avvia progetto") { model.startProject(named: group.projectName) }
                        .disabled(group.services.allSatisfy { $0.processAlive })
                    Button("Ferma progetto") { model.stopProject(named: group.projectName) }
                        .disabled(!group.services.contains { $0.processAlive })
                }
            }
        }
        Divider()
        Button("Avvia tutti") { model.startAll() }
            .disabled(model.services.allSatisfy { $0.processAlive })
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Riavvia tutti") { model.restartAll() }
            .disabled(!model.anyRunning)
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Ferma tutti") { model.stopAll() }
            .disabled(!model.anyRunning)
            .help("Ferma subito, senza conferma")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        Divider()
        Button("Apri launcher") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut("0", modifiers: [.command])
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

    /// Emoji riassuntiva di un progetto per il titolo del submenu: verde se almeno uno gira,
    /// rosso se almeno uno è crashato, altrimenti grigio.
    private func projectEmoji(_ services: [ServiceController]) -> String {
        if services.contains(where: { if case .crashed = $0.status { return true }; return false }) {
            return "🔴"
        }
        if services.contains(where: { $0.processAlive }) { return "🟢" }
        return "⚪️"
    }
}
