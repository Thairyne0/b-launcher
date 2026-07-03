import SwiftUI

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

                Toggle("Autoscroll", isOn: $autoscroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button("Pulisci") { logs.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs.visibleLines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(white: 0.88))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 10))
                .onChange(of: logs.lines.last?.id) { _, newID in
                    guard autoscroll, logs.searchText.isEmpty, let newID else { return }
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
    }
}
