import AppKit
import SwiftUI

/// Finestra "Informazioni su Backend Launcher" (`Window(id: "about")` in `BackendLauncherApp`,
/// sostituisce `CommandGroup(replacing: .appInfo)`). Dimensione fissa: non è un pannello di
/// lavoro, solo credit/versione, quindi non ha bisogno di essere ridimensionabile.
struct AboutView: View {
    @State private var showCopiedConfirmation = false

    private var versionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Versione \(shortVersion) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            appIconImage
                .frame(width: 96, height: 96)

            Text("Backend Launcher")
                .font(.title.weight(.semibold))

            Text("Launcher nativo per backend di sviluppo")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                copyVersionToPasteboard()
            } label: {
                Text(showCopiedConfirmation ? "Copiato ✓" : versionString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copia versione")

            Divider()
                .padding(.horizontal, 40)

            Text("Fatto con Claude Code")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 360, height: 420)
    }

    /// Stesso pattern/motivazione di `WelcomeView.appIconImage`: lookup da bundle con fallback
    /// a un SF Symbol quando l'app gira senza bundle (test, `swift run`).
    @ViewBuilder
    private var appIconImage: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "shippingbox.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private func copyVersionToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(versionString, forType: .string)

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedConfirmation = false
        }
    }
}
