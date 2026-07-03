import AppKit
import SwiftUI

/// Sheet di benvenuto al primo avvio (`@AppStorage("hasSeenWelcome")`, pilotata da `ContentView`).
/// Un unico scroll verticale con tre "pannelli" concettuali invece di un wizard a pagine: per un
/// contenuto così breve un paging con indicatori/frecce sarebbe complessità in più senza
/// beneficio reale — l'utente può leggere tutto e uscire con un solo bottone "Inizia".
struct WelcomeView: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    gettingStartedSection
                    goodToKnowSection
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("Inizia") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        VStack(spacing: 10) {
            appIconImage
                .frame(width: 64, height: 64)

            Text("Benvenuto in Backend Launcher")
                .font(.title2.weight(.semibold))

            Text("Avvia, osserva e gestisci i backend di sviluppo dei tuoi progetti.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// Icona dell'app dal bundle (`NSImage.applicationIconName`, risolta da Launch Services
    /// quando l'app gira come `.app` bundlato). Da `swift run`/binario nudo (test, sviluppo)
    /// questa lookup può restituire `nil` o un'icona generica: fallback a un SF Symbol così la
    /// sheet resta comunque leggibile senza dipendere da un asset catalog che questo target
    /// non ha (nessuna cartella `.xcassets` nel progetto).
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

    private var gettingStartedSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Per iniziare")
                    .font(.headline)

                startingRow(icon: "plus",
                            text: "Crea un progetto e aggiungi i backend a mano")

                startingRow(icon: "square.and.arrow.down",
                            text: "Importa un template .blauncher.json da un collega")

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Genera il template con Claude Code")
                        ClaudeCodePromptCopyButton()
                    }
                }
            }
        }
    }

    private func startingRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text)
        }
    }

    private var goodToKnowSection: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Da sapere")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    shortcutRow("⌘K", "Palette comandi")
                    shortcutRow("⌘E", "Espandi/comprimi tutti i terminali")
                    shortcutRow("⌘⇧A", "Avvia tutti")
                    shortcutRow("⌘⇧S", "Ferma tutti")
                    shortcutRow("⌘⇧R", "Riavvia tutti")
                    shortcutRow("⌘?", "Aiuto")
                }

                Text("Trovi tutto in Aiuto.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack(spacing: 8) {
            Text(shortcut)
                .font(.callout.monospaced().weight(.medium))
                .frame(width: 50, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Bottone "Genera con Claude Code…" che copia il prompt (`ClaudeCodePrompt.make()`) negli
/// appunti e mostra una conferma transiente "Copiato ✓" per 2s. Isolato in una view separata
/// (invece che stato inline in `WelcomeView`) per lo stesso motivo del bottone gemello in
/// `SidebarView`: il flip di label è una piccola macchina a stati autosufficiente.
private struct ClaudeCodePromptCopyButton: View {
    @State private var showCopiedConfirmation = false

    var body: some View {
        Button {
            copyPrompt()
        } label: {
            if showCopiedConfirmation {
                Label("Copiato ✓", systemImage: "checkmark")
            } else {
                Label("Copia prompt per Claude Code", systemImage: "doc.on.clipboard")
            }
        }
        .buttonStyle(.bordered)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ClaudeCodePrompt.make(), forType: .string)

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedConfirmation = false
        }
    }
}
