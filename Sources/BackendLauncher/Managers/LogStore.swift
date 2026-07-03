import Foundation
import Observation

/// Livello di severità di una riga di log, derivato a ingest-time.
enum LogLevel {
    case normal, debug, warning, error
}

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let level: LogLevel
}

/// Ring buffer di righe di log per un servizio. Tutte le mutazioni su MainActor.
@MainActor
@Observable
final class LogStore {
    /// Filtro di visibilità per livello, applicato in `visibleLines` insieme a `searchText`.
    enum LevelFilter: String, CaseIterable {
        case all = "Tutti"
        case warnPlus = "Warn+"
        case errors = "Errori"
    }

    /// Modalità di ricerca: `.filter` nasconde le righe non corrispondenti, `.highlight`
    /// le mantiene tutte visibili (il filtro di livello resta comunque applicato) e lascia
    /// che sia la view a evidenziare i match.
    enum SearchMode: String, CaseIterable {
        case filter = "Filtra"
        case highlight = "Evidenzia"
    }

    private(set) var lines: [LogLine] = []
    private(set) var errorCount = 0
    var searchText: String = ""
    var levelFilter: LevelFilter = .all
    var searchMode: SearchMode = .filter

    private var nextID = 0
    private var partial = ""
    private let maxLines: Int

    // \u{1B}\[ ... lettera finale — copre colori e cursor codes CSI
    private static let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    /// Marker di avvio emesso da ServiceController all'inizio di ogni esecuzione — contratto
    /// interno concordato per resettare il conteggio errori senza che ServiceController debba
    /// conoscere LogStore. Se il prefisso cambia lato ServiceController, aggiornare qui.
    private static let launcherStartBanner = "[launcher] ── avvio"

    /// `maxLines` esplicito (usato dai test) ha priorità; altrimenti legge
    /// `AppSettings.maxLogLines` — il cap si applica solo ai nuovi avvii, non retroattivamente
    /// ai LogStore già esistenti.
    init(maxLines: Int? = nil) {
        self.maxLines = maxLines ?? AppSettings.maxLogLines
    }

    var visibleLines: [LogLine] {
        let levelFiltered = self.levelFiltered
        guard searchMode == .filter, !searchText.isEmpty else { return levelFiltered }
        return levelFiltered.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    /// Id delle righe (dopo `levelFilter`, indipendentemente da `searchMode`) il cui testo
    /// contiene `searchText` case-insensitive. Vuoto quando `searchText` è vuoto.
    var searchMatchIDs: [Int] {
        guard !searchText.isEmpty else { return [] }
        return levelFiltered
            .filter { $0.text.localizedCaseInsensitiveContains(searchText) }
            .map(\.id)
    }

    private var levelFiltered: [LogLine] {
        switch levelFilter {
        case .all:
            return lines
        case .warnPlus:
            return lines.filter { $0.level == .error || $0.level == .warning }
        case .errors:
            return lines.filter { $0.level == .error }
        }
    }

    func ingest(_ chunk: String) {
        var buffer = partial + Self.stripANSI(chunk)
        var incoming: [LogLine] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let text = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            let level = Self.classify(text)
            incoming.append(LogLine(id: nextID, text: text, level: level))
            nextID += 1
            if level == .error {
                errorCount += 1
            }
            if text.hasPrefix(Self.launcherStartBanner) {
                errorCount = 0
            }
        }
        partial = buffer
        guard !incoming.isEmpty else { return }
        lines.append(contentsOf: incoming)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// Da chiamare su EOF del processo: emette l'eventuale riga finale senza newline.
    func flushPartial() {
        guard !partial.isEmpty else { return }
        let text = partial
        partial = ""
        ingest(text + "\n")
    }

    func clear() {
        lines.removeAll()
        partial = ""
        errorCount = 0
    }

    func resetErrorCount() {
        errorCount = 0
    }

    /// Classificazione pura di una riga di log (post strip-ANSI) in un `LogLevel`.
    /// Ordine di valutazione: prefisso [launcher] per primo (mai errore), poi error, warning, debug.
    static func classify(_ line: String) -> LogLevel {
        if line.hasPrefix("[launcher]") {
            return .normal
        }
        if line.contains(" ERROR ") || line.contains(" FATAL ") || line.hasPrefix("npm ERR!") {
            return .error
        }
        if line.contains(" WARN ") {
            return .warning
        }
        if line.contains(" DEBUG ") || line.contains(" VERBOSE ") {
            return .debug
        }
        return .normal
    }

    /// Costruisce il blocco di testo copiabile per un errore: la riga stessa più tutte le righe
    /// immediatamente successive (per ordine di id in `lines`) che sembrano stack trace, cioè
    /// livello `.normal` e che iniziano con spazio/tab oppure con "at ". Si ferma alla prima riga
    /// che non rispetta questi criteri.
    static func errorBlock(startingAt id: Int, in lines: [LogLine]) -> String {
        guard let startIndex = lines.firstIndex(where: { $0.id == id }) else { return "" }
        var collected = [lines[startIndex].text]
        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index]
            let isStackTraceish = line.level == .normal
                && (line.text.hasPrefix(" ") || line.text.hasPrefix("\t") || line.text.hasPrefix("at "))
            guard isStackTraceish else { break }
            collected.append(line.text)
            index += 1
        }
        return collected.joined(separator: "\n")
    }

    private static func stripANSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansiPattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
