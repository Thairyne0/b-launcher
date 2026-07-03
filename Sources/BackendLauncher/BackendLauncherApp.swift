import AppKit
import SwiftUI

/// Delegate: attivazione app da binario nudo (swift run) + conferma quit con backend attivi.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        CrashNotifier.requestAuthorizationIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 560, height: 720)
    }
}
