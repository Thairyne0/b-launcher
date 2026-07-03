import AppKit
import SwiftUI

/// Vista log su NSTextView nativo: selezione multi-riga, copia nativa, colori per livello.
struct LogTextView: NSViewRepresentable {
    var lines: [LogLine]
    var searchText: String
    var currentMatchID: Int?
    var autoscroll: Bool
    var fontSize: Double
    var onErrorBlockCopy: (Int) -> String   // id riga errore → testo blocco (per il menu contestuale)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ContextMenuTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.coordinator = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.userDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(
            lines: lines,
            searchText: searchText,
            currentMatchID: currentMatchID,
            autoscroll: autoscroll,
            fontSize: fontSize,
            onErrorBlockCopy: onErrorBlockCopy
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        weak var textView: ContextMenuTextView?
        weak var scrollView: NSScrollView?

        private var lastLines: [LogLine] = []
        private var lastSearchText: String = ""
        private var lastMatchID: Int?
        private var lastAutoscrollFlag = true
        private var lastFontSize: Double = 12
        /// Mappa id riga → range di caratteri nel textStorage, per il context menu.
        private(set) var lineRanges: [(id: Int, level: LogLevel, range: NSRange)] = []
        private var wasNearBottom = true
        var onErrorBlockCopy: (Int) -> String = { _ in "" }

        private var paragraphStyle = LogTextView.Coordinator.makeParagraphStyle(fontSize: 12)
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        private static func makeParagraphStyle(fontSize: Double) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.75 // proporzionale: ~9pt a 12pt monospace
            return style
        }

        func apply(
            lines: [LogLine],
            searchText: String,
            currentMatchID: Int?,
            autoscroll: Bool,
            fontSize: Double,
            onErrorBlockCopy: @escaping (Int) -> String
        ) {
            self.onErrorBlockCopy = onErrorBlockCopy
            guard let textView, let scrollView else { return }

            let searchChanged = searchText != lastSearchText
            let autoscrollJustEnabled = autoscroll && !lastAutoscrollFlag
            let matchChanged = currentMatchID != lastMatchID
            let fontSizeChanged = fontSize != lastFontSize

            if fontSizeChanged {
                font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                paragraphStyle = Self.makeParagraphStyle(fontSize: fontSize)
            }

            // Appendibile solo se: ricerca invariata, il buffer precedente non è vuoto,
            // il nuovo array è strettamente più lungo, e l'ultimo id del vecchio buffer
            // compare esattamente in coda (nessun trim/reset di mezzo, ids monotonici).
            let isPureAppend: Bool = {
                guard !searchChanged, !fontSizeChanged, !lastLines.isEmpty, lines.count > lastLines.count else { return false }
                guard lines.first?.id == lastLines.first?.id else { return false }
                return lines[lastLines.count - 1].id == lastLines[lastLines.count - 1].id
            }()

            let nearBottomBefore = isNearBottom(scrollView)

            if isPureAppend {
                let newLines = Array(lines[lastLines.count...])
                appendLines(newLines, to: textView, searchText: searchText, currentMatchID: currentMatchID)
                // Il match evidenziato potrebbe essere una riga già renderizzata: se è cambiato
                // ed è precedente alle righe appena aggiunte, serve un rebuild per aggiornarne lo sfondo.
                if matchChanged {
                    rebuild(lines: lines, searchText: searchText, currentMatchID: currentMatchID, textView: textView)
                }
            } else if fontSizeChanged || searchChanged || !linesEqual(lines, lastLines) || matchChanged {
                rebuild(lines: lines, searchText: searchText, currentMatchID: currentMatchID, textView: textView)
            }

            lastLines = lines
            lastSearchText = searchText
            lastMatchID = currentMatchID
            lastAutoscrollFlag = autoscroll
            lastFontSize = fontSize

            if let currentMatchID, currentMatchID != lastMatchIDScrolledTo {
                scrollToLine(id: currentMatchID, in: textView)
                lastMatchIDScrolledTo = currentMatchID
            } else if autoscroll, (nearBottomBefore || autoscrollJustEnabled || wasNearBottom) {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private var lastMatchIDScrolledTo: Int?

        private func linesEqual(_ a: [LogLine], _ b: [LogLine]) -> Bool {
            a.count == b.count && a.first?.id == b.first?.id && a.last?.id == b.last?.id
        }

        private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visibleRect = scrollView.contentView.bounds
            let maxY = documentView.bounds.height
            return (maxY - visibleRect.maxY) <= 40
        }

        @objc func userDidScroll() {
            guard let scrollView else { return }
            wasNearBottom = isNearBottom(scrollView)
        }

        private func attributedLine(_ line: LogLine, searchText: String) -> NSMutableAttributedString {
            let text = (line.text.isEmpty ? " " : line.text) + "\n"
            let attr = NSMutableAttributedString(string: text)
            let full = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.font, value: font, range: full)
            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
            attr.addAttribute(.foregroundColor, value: color(for: line.level), range: full)

            if !searchText.isEmpty {
                let lowerText = text.lowercased()
                let lowerQuery = searchText.lowercased()
                var searchRange = lowerText.startIndex..<lowerText.endIndex
                while let range = lowerText.range(of: lowerQuery, range: searchRange) {
                    let nsRange = NSRange(range, in: lowerText)
                    attr.addAttribute(.backgroundColor, value: NSColor.yellow.withAlphaComponent(0.45), range: nsRange)
                    attr.addAttribute(.foregroundColor, value: NSColor.black, range: nsRange)
                    searchRange = range.upperBound..<lowerText.endIndex
                }
            }
            return attr
        }

        private func color(for level: LogLevel) -> NSColor {
            switch level {
            case .error: NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
            case .warning: NSColor(red: 1.0, green: 0.83, blue: 0.35, alpha: 1)
            case .debug: NSColor(white: 0.55, alpha: 1)
            case .normal: NSColor(white: 0.88, alpha: 1)
            }
        }

        private func appendLines(
            _ newLines: [LogLine],
            to textView: ContextMenuTextView,
            searchText: String,
            currentMatchID: Int?
        ) {
            guard let storage = textView.textStorage else { return }
            let start = storage.length
            let toAppend = NSMutableAttributedString()
            var cursor = start
            for line in newLines {
                let rendered = attributedLine(line, searchText: searchText)
                if line.id == currentMatchID {
                    applyFullLineHighlight(to: rendered)
                }
                lineRanges.append((id: line.id, level: line.level, range: NSRange(location: cursor, length: rendered.length)))
                cursor += rendered.length
                toAppend.append(rendered)
            }
            storage.beginEditing()
            storage.append(toAppend)
            storage.endEditing()
            textView.contextLineRanges = lineRanges
        }

        private func applyFullLineHighlight(to attr: NSMutableAttributedString) {
            let full = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.backgroundColor, value: NSColor.yellow.withAlphaComponent(0.15), range: full)
        }

        private func rebuild(
            lines: [LogLine],
            searchText: String,
            currentMatchID: Int?,
            textView: ContextMenuTextView
        ) {
            guard let storage = textView.textStorage else { return }
            let result = NSMutableAttributedString()
            var ranges: [(id: Int, level: LogLevel, range: NSRange)] = []
            var cursor = 0
            for line in lines {
                let rendered = attributedLine(line, searchText: searchText)
                if line.id == currentMatchID {
                    applyFullLineHighlight(to: rendered)
                }
                ranges.append((id: line.id, level: line.level, range: NSRange(location: cursor, length: rendered.length)))
                cursor += rendered.length
                result.append(rendered)
            }
            storage.beginEditing()
            storage.setAttributedString(result)
            storage.endEditing()
            lineRanges = ranges
            textView.contextLineRanges = ranges
        }

        private func scrollToLine(id: Int, in textView: NSTextView) {
            guard let entry = lineRanges.first(where: { $0.id == id }) else { return }
            textView.scrollRangeToVisible(entry.range)
            // Centra la riga nella viewport, quando possibile.
            if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer, let scrollView = textView.enclosingScrollView {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let visibleHeight = scrollView.contentView.bounds.height
                let targetY = max(0, rect.midY - visibleHeight / 2)
                let clampedY = min(targetY, max(0, textView.bounds.height - visibleHeight))
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

/// NSTextView con menu contestuale esteso: "Copia riga" e, per le righe di errore, "Copia blocco errore".
final class ContextMenuTextView: NSTextView {
    weak var coordinator: LogTextView.Coordinator?
    var contextLineRanges: [(id: Int, level: LogLevel, range: NSRange)] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        guard let entry = contextLineRanges.first(where: { NSLocationInRange(charIndex, $0.range) || charIndex == $0.range.location + $0.range.length }) else {
            return menu
        }

        guard let lineText = textStorage?.attributedSubstring(from: entry.range).string else { return menu }
        let trimmedLine = lineText.hasSuffix("\n") ? String(lineText.dropLast()) : lineText

        menu?.addItem(.separator())

        let copyLineItem = NSMenuItem(title: "Copia riga", action: #selector(copyLineAction(_:)), keyEquivalent: "")
        copyLineItem.target = self
        copyLineItem.representedObject = trimmedLine
        menu?.addItem(copyLineItem)

        if entry.level == .error, let coordinator {
            let copyBlockItem = NSMenuItem(title: "Copia blocco errore", action: #selector(copyBlockAction(_:)), keyEquivalent: "")
            copyBlockItem.target = self
            copyBlockItem.representedObject = coordinator.onErrorBlockCopy(entry.id)
            menu?.addItem(copyBlockItem)
        }

        return menu
    }

    @objc private func copyLineAction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyBlockAction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
