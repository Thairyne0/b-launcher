import Foundation
import Testing
@testable import BackendLauncher

@Suite struct PaletteMatcherTests {
    private func item(_ id: String, _ title: String, subtitle: String? = nil) -> PaletteItem {
        PaletteItem(id: id, title: title, subtitle: subtitle, systemImage: "square")
    }

    private let sample: [PaletteItem] = [
        PaletteItem(id: "1", title: "Vai a skillgateway", subtitle: "Skillera", systemImage: "server.rack"),
        PaletteItem(id: "2", title: "Vai a skillid", subtitle: "Skillera", systemImage: "server.rack"),
        PaletteItem(id: "3", title: "Avvia tutti", subtitle: nil, systemImage: "play.fill"),
        PaletteItem(id: "4", title: "Ferma tutti", subtitle: nil, systemImage: "stop.fill"),
    ]

    @Test func emptyQueryReturnsAllItemsInOriginalOrder() {
        let result = PaletteMatcher.filter(sample, query: "")
        #expect(result == sample)
    }

    @Test func blankQueryReturnsAllItems() {
        let result = PaletteMatcher.filter(sample, query: "   ")
        #expect(result == sample)
    }

    @Test func subsequenceMatchFindsNonContiguousLetters() {
        // "gat" è sottosequenza contigua di "skillgateway" (via il titolo "Vai a skillgateway").
        let result = PaletteMatcher.filter(sample, query: "gat")
        #expect(result.contains { $0.id == "1" })
        #expect(!result.contains { $0.id == "2" })
    }

    @Test func nonContiguousSubsequenceStillMatches() {
        // "sgw" è sottosequenza non contigua di "skillgateway" (s..g..w).
        let items = [item("x", "skillgateway")]
        let result = PaletteMatcher.filter(items, query: "sgw")
        #expect(result.map(\.id) == ["x"])
    }

    @Test func noMatchReturnsEmpty() {
        let result = PaletteMatcher.filter(sample, query: "zzzzz-no-match")
        #expect(result.isEmpty)
    }

    @Test func matchIsCaseInsensitive() {
        let lower = PaletteMatcher.filter(sample, query: "gateway")
        let upper = PaletteMatcher.filter(sample, query: "GATEWAY")
        let mixed = PaletteMatcher.filter(sample, query: "GaTeWaY")
        #expect(lower.map(\.id) == upper.map(\.id))
        #expect(lower.map(\.id) == mixed.map(\.id))
        #expect(lower.contains { $0.id == "1" })
    }

    @Test func prefixMatchRanksAboveSubsequenceMatch() {
        let items = [
            item("subsequence", "Ferma skillgateway"),   // "gat" appare come sottosequenza a metà stringa
            item("prefix", "gateway avanzato"),          // "gat" è prefisso del titolo
        ]
        let result = PaletteMatcher.filter(items, query: "gat")
        #expect(result.map(\.id) == ["prefix", "subsequence"])
    }

    @Test func wordBoundaryMatchRanksAboveGenericSubsequence() {
        let items = [
            item("mid-word", "riavgatvia"),        // "gat" sepolto in mezzo a una parola sola, non a inizio parola
            item("boundary", "riavvia gateway ora"), // "gat" inizia un nuovo "word" dopo uno spazio
        ]
        let result = PaletteMatcher.filter(items, query: "gat")
        #expect(result.map(\.id) == ["boundary", "mid-word"])
    }

    @Test func prefixRanksAboveWordBoundaryWhichRanksAboveSubsequence() {
        let items = [
            item("subsequence", "riavgatvia"),
            item("boundary", "riavvia gateway ora"),
            item("prefix", "gateway riavvio"),
        ]
        let result = PaletteMatcher.filter(items, query: "gat")
        #expect(result.map(\.id) == ["prefix", "boundary", "subsequence"])
    }

    @Test func matchIsStableForEqualRank() {
        // Stesso identico titolo/rank per due elementi diversi: l'ordine originale va preservato.
        let items = [
            item("a", "gateway uno"),
            item("b", "gateway due"),
        ]
        let result = PaletteMatcher.filter(items, query: "gateway")
        #expect(result.map(\.id) == ["a", "b"])
    }

    @Test func matchesAgainstSubtitleToo() {
        // "Skillera" compare solo nel subtitle, non nel titolo — deve comunque matchare.
        let result = PaletteMatcher.filter(sample, query: "skillera")
        #expect(result.map(\.id).sorted() == ["1", "2"])
    }

    @Test func whitespaceInQueryIsTrimmed() {
        let result = PaletteMatcher.filter(sample, query: "  gateway  ")
        #expect(result.contains { $0.id == "1" })
    }
}
