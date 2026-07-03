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
        ScrollViewReader { proxy in
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
                            stepMatch(by: -1, proxy: proxy)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Match precedente")

                        Button {
                            stepMatch(by: 1, proxy: proxy)
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

                logArea(proxy: proxy)
            }
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
    private func logArea(proxy: ScrollViewProxy) -> some View {
        Group {
            if logs.visibleLines.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs.visibleLines) { line in
                            Text(highlighted(line.text.isEmpty ? " " : line.text, matching: logs.searchText))
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(1.5)
                                .foregroundStyle(color(for: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.id == currentMatchID ? Color.yellow.opacity(0.15) : Color.clear)
                                .id(line.id)
                                .contextMenu {
                                    Button("Copia riga") {
                                        copyToPasteboard(line.text)
                                    }
                                    if line.level == .error {
                                        Button("Copia blocco errore") {
                                            copyToPasteboard(LogStore.errorBlock(startingAt: line.id, in: logs.lines))
                                        }
                                    }
                                    Button("Copia tutto il visibile") {
                                        copyToPasteboard(logs.visibleLines.map(\.text).joined(separator: "\n"))
                                    }
                                }
                        }
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.92), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .onChange(of: logs.lines.last?.id) { _, newID in
            guard autoscroll, logs.searchText.isEmpty, let newID else { return }
            proxy.scrollTo(newID, anchor: .bottom)
        }
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

    private func stepMatch(by delta: Int, proxy: ScrollViewProxy) {
        let matches = logs.searchMatchIDs
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentMatchIndex = ((currentMatchIndex + delta) % count + count) % count
        proxy.scrollTo(matches[currentMatchIndex], anchor: .center)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: Color(red: 1.0, green: 0.42, blue: 0.42)
        case .warning: Color(red: 1.0, green: 0.83, blue: 0.35)
        case .debug: Color(white: 0.55)
        case .normal: Color(white: 0.88)
        }
    }

    /// Costruisce un `AttributedString` evidenziando in giallo tutte le occorrenze
    /// case-insensitive di `query` in `text`. Se `query` è vuota, ritorna il testo invariato.
    private func highlighted(_ text: String, matching query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }

        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        guard !lowerQuery.isEmpty else { return result }

        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = Color.yellow.opacity(0.45)
                result[attrRange].foregroundColor = .black
            }
            searchStart = range.upperBound
        }
        return result
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
