import SwiftUI
import AppKit

/// Log live di un servizio: monospace, sfondo scuro, ricerca, autoscroll, pulisci.
struct TerminalView: View {
    @Bindable var logs: LogStore
    @State private var autoscroll = true
    @State private var currentMatchIndex = 0

    private var currentMatchOrdinal: Int {
        let matches = logs.searchMatchIDs
        guard !matches.isEmpty else { return 0 }
        // l'indice può essere stantio dopo un cambio di filtro/trim del buffer
        guard matches.indices.contains(currentMatchIndex) else { return 1 }
        return currentMatchIndex + 1
    }

    private var currentMatchID: Int? {
        let matches = logs.searchMatchIDs
        guard matches.indices.contains(currentMatchIndex) else { return nil }
        return matches[currentMatchIndex]
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Cerca nei log", text: $logs.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: .capsule)
                .frame(maxWidth: 240)

                if !logs.searchText.isEmpty {
                    Text("\(currentMatchOrdinal)/\(logs.searchMatchIDs.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button {
                        stepMatch(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Match precedente")

                    Button {
                        stepMatch(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Match successivo")
                }

                searchModeToggle

                Picker("", selection: $logs.levelFilter) {
                    ForEach(LogStore.LevelFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 180)
                .labelsHidden()

                Spacer()

                Toggle("Autoscroll", isOn: $autoscroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)

                Button {
                    copyToPasteboard(logs.visibleLines.map(\.text).joined(separator: "\n"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copia log visibile")

                Button {
                    logs.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Pulisci")
            }

            logArea
        }
        .onChange(of: logs.searchText) { _, _ in
            currentMatchIndex = 0
        }
        .onChange(of: logs.levelFilter) { _, _ in
            currentMatchIndex = 0
        }
    }

    private var searchModeToggle: some View {
        Button {
            logs.searchMode = logs.searchMode == .filter ? .highlight : .filter
        } label: {
            Image(systemName: logs.searchMode == .filter
                  ? "line.3.horizontal.decrease.circle"
                  : "highlighter")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(logs.searchMode == .filter
              ? "Modalità: filtra righe non corrispondenti"
              : "Modalità: evidenzia senza nascondere righe")
    }

    @ViewBuilder
    private var logArea: some View {
        Group {
            if logs.visibleLines.isEmpty {
                emptyState
            } else {
                LogTextView(
                    lines: logs.visibleLines,
                    searchText: logs.searchText,
                    currentMatchID: currentMatchID,
                    autoscroll: autoscroll,
                    onErrorBlockCopy: { id in LogStore.errorBlock(startingAt: id, in: logs.lines) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.92), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(logs.lines.isEmpty
                 ? "Nessun output — avvia il servizio"
                 : "Nessuna riga corrisponde a filtro o ricerca")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func stepMatch(by delta: Int) {
        let matches = logs.searchMatchIDs
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentMatchIndex = ((currentMatchIndex + delta) % count + count) % count
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
