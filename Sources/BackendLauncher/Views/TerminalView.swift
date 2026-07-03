import SwiftUI
import AppKit

/// Log live di un servizio: monospace, sfondo scuro, ricerca, autoscroll, pulisci.
struct TerminalView: View {
    @Bindable var logs: LogStore
    @State private var autoscroll = true

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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs.visibleLines) { line in
                            Text(highlighted(line.text.isEmpty ? " " : line.text, matching: logs.searchText))
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(1.5)
                                .foregroundStyle(color(for: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                .background(Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.92), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                .onChange(of: logs.lines.last?.id) { _, newID in
                    guard autoscroll, logs.searchText.isEmpty, let newID else { return }
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
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
