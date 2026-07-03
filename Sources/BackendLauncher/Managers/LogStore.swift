import Foundation
import Observation

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Ring buffer di righe di log per un servizio. Tutte le mutazioni su MainActor.
@MainActor
@Observable
final class LogStore {
    private(set) var lines: [LogLine] = []
    var searchText: String = ""

    private var nextID = 0
    private var partial = ""
    private let maxLines: Int

    // \u{1B}\[ ... lettera finale — copre colori e cursor codes CSI
    private static let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    init(maxLines: Int = 5000) {
        self.maxLines = maxLines
    }

    var visibleLines: [LogLine] {
        guard !searchText.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    func ingest(_ chunk: String) {
        var buffer = partial + Self.stripANSI(chunk)
        var incoming: [LogLine] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let text = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            incoming.append(LogLine(id: nextID, text: text))
            nextID += 1
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
    }

    private static func stripANSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansiPattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
