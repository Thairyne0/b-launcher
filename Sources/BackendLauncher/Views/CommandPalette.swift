import SwiftUI
import Observation

/// Un'azione selezionabile dalla palette comandi (⌘K). `id` deve essere univoco nell'elenco
/// passato a `PaletteMatcher.filter` — l'azione vera e propria non vive qui: il chiamante
/// (`ContentView`) costruisce l'elenco e, alla selezione, fa dispatch in base a `id`.
struct PaletteItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
}

/// Matcher puro (nessuna dipendenza da SwiftUI/AppKit) per la palette comandi: filtra e
/// ordina `items` in base a una query fuzzy case-insensitive.
///
/// Regole di ranking (dalla più alla meno rilevante):
/// 1. `prefix`  — il titolo (o il sottotitolo) inizia esattamente con la query.
/// 2. `boundary` — la query inizia esattamente all'inizio di una "parola" (dopo uno spazio o
///    un separatore), es. "gat" in "riavvia gateway ora".
/// 3. `subsequence` — i caratteri della query compaiono nell'ordine dato ma non
///    necessariamente contigui né a inizio parola, es. "sgw" in "skillgateway".
///
/// A parità di rank l'ordine è quello originale di `items` (sort stabile): nessun criterio
/// secondario arbitrario che possa sembrare casuale all'utente.
enum PaletteMatcher {
    private enum Rank: Int {
        case prefix = 0
        case boundary = 1
        case subsequence = 2
    }

    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let needle = trimmed.lowercased()

        let ranked: [(offset: Int, rank: Rank, item: PaletteItem)] = items.enumerated().compactMap { offset, item in
            guard let rank = bestRank(for: item, needle: needle) else { return nil }
            return (offset, rank, item)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank.rawValue < rhs.rank.rawValue }
                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }

    /// Rank migliore tra titolo e sottotitolo (se presente), o `nil` se la query non
    /// matcha nessuno dei due nemmeno come sottosequenza.
    private static func bestRank(for item: PaletteItem, needle: String) -> Rank? {
        let candidates = [item.title, item.subtitle].compactMap { $0?.lowercased() }
        let ranks = candidates.compactMap { rank(for: $0, needle: needle) }
        return ranks.min(by: { $0.rawValue < $1.rawValue })
    }

    private static func rank(for haystack: String, needle: String) -> Rank? {
        if haystack.hasPrefix(needle) { return .prefix }
        if hasWordBoundaryMatch(haystack, needle) { return .boundary }
        if isSubsequence(needle, of: haystack) { return .subsequence }
        return nil
    }

    /// Vero se `needle` inizia esattamente all'inizio di una "parola" di `haystack`, dove una
    /// parola è la porzione di stringa che segue uno spazio (o l'inizio stringa, già coperto
    /// da `hasPrefix` sopra — qui si cercano solo i confini INTERNI).
    private static func hasWordBoundaryMatch(_ haystack: String, _ needle: String) -> Bool {
        let words = haystack.split(separator: " ")
        // Il primo "word" coincide col prefisso dell'intera stringa, già gestito da `.prefix`;
        // si considerano solo le parole successive per non duplicare quel rank.
        return words.dropFirst().contains { $0.hasPrefix(needle) }
    }

    /// Vero se i caratteri di `needle` compaiono in `haystack` nello stesso ordine, non
    /// necessariamente contigui (subsequence classica, stile "fuzzy finder").
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var needleIndex = needle.startIndex
        for char in haystack {
            if char == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
                if needleIndex == needle.endIndex { return true }
            }
        }
        return false
    }
}

/// Stato condiviso di visibilità della palette: un piccolo `@Observable` singleton invece di
/// un campo su `AppModel` (fuori dai file di competenza di questa feature) — il bottone di menu
/// "Apri palette comandi" (⌘K, in `BackendLauncherApp`) e l'overlay in `ContentView` osservano
/// entrambi la stessa istanza senza bisogno di passarsi binding attraverso la gerarchia di scene.
@MainActor
@Observable
final class PaletteState {
    static let shared = PaletteState()

    var isPresented = false

    /// Init non-privato: `.shared` per la UI reale, ma i test (se mai servissero) possono
    /// costruire un'istanza isolata — stesso pattern di `ToastCenter`.
    init() {}
}

/// Overlay della palette comandi: scrim a tutto schermo (tap per chiudere) + pannello glass
/// centrato nel terzo superiore con campo di ricerca e risultati navigabili da tastiera.
/// Il contenuto degli `items` e l'azione di `onSelect` sono di competenza del chiamante
/// (`ContentView`, che ha accesso al model): questa view è puro layout + gestione tastiera.
struct CommandPaletteView: View {
    let items: [PaletteItem]
    let onSelect: (PaletteItem) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var searchFieldFocused: Bool

    private var results: [PaletteItem] {
        Array(PaletteMatcher.filter(items, query: query).prefix(8))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            panel
                .padding(.top, 96)
        }
        .onAppear { searchFieldFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField

            if !results.isEmpty {
                Divider()
                resultsList
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nessun risultato")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Cerca un comando…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFieldFocused)
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.return) { selectHighlighted(); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultsList: some View {
        VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                resultRow(result, highlighted: index == highlightedIndex)
                    .onTapGesture {
                        onSelect(result)
                        onDismiss()
                    }
            }
        }
        .padding(8)
    }

    private func resultRow(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.body)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        highlightedIndex = ((highlightedIndex + delta) % count + count) % count
    }

    private func selectHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        onSelect(results[highlightedIndex])
        onDismiss()
    }
}
