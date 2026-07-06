import Foundation
import Testing
@testable import BackendLauncher

@Suite struct ANSIParserTests {
    @Test func plainTextPassesThrough() {
        let result = ANSIParser.parse("riga normale")
        #expect(result.clean == "riga normale")
        #expect(result.spans.isEmpty)
    }

    @Test func foregroundColorSpan() {
        let result = ANSIParser.parse("\u{1B}[31mrosso\u{1B}[0m dopo")
        #expect(result.clean == "rosso dopo")
        #expect(result.spans == [ANSISpan(start: 0, length: 5, colorIndex: 1, bold: false)])
    }

    @Test func brightColorMapsToUpperPalette() {
        let result = ANSIParser.parse("\u{1B}[92mok\u{1B}[39m!")
        #expect(result.clean == "ok!")
        #expect(result.spans == [ANSISpan(start: 0, length: 2, colorIndex: 10, bold: false)])
    }

    @Test func boldWithoutColor() {
        let result = ANSIParser.parse("\u{1B}[1mgrassetto\u{1B}[22m fine")
        #expect(result.clean == "grassetto fine")
        #expect(result.spans == [ANSISpan(start: 0, length: 9, colorIndex: nil, bold: true)])
    }

    @Test func combinedBoldAndColor() {
        let result = ANSIParser.parse("\u{1B}[1;33mwarn\u{1B}[0m")
        #expect(result.spans == [ANSISpan(start: 0, length: 4, colorIndex: 3, bold: true)])
    }

    @Test func unclosedColorRunsToEndOfLine() {
        let result = ANSIParser.parse("\u{1B}[36mciano fino in fondo")
        #expect(result.clean == "ciano fino in fondo")
        #expect(result.spans == [ANSISpan(start: 0, length: 19, colorIndex: 6, bold: false)])
    }

    @Test func color256LowIndexesSupported() {
        let result = ANSIParser.parse("\u{1B}[38;5;12mblu\u{1B}[0m")
        #expect(result.spans == [ANSISpan(start: 0, length: 3, colorIndex: 12, bold: false)])
        // Indici fuori dalla palette base: testo pulito, nessuno span colore.
        let high = ANSIParser.parse("\u{1B}[38;5;200mx\u{1B}[0m")
        #expect(high.clean == "x")
        #expect(high.spans.isEmpty)
    }

    @Test func nonSGRSequencesAreStripped() {
        #expect(ANSIParser.parse("\u{1B}[2Kpulito").clean == "pulito")
        #expect(ANSIParser.parse("\u{1B}]0;titolo\u{07}testo").clean == "testo")
        #expect(ANSIParser.parse("\u{1B}]0;titolo\u{1B}\\testo").clean == "testo")
    }

    @Test func malformedTrailingEscapeDoesNotCrash() {
        #expect(ANSIParser.parse("testo\u{1B}[31").clean == "testo")
        #expect(ANSIParser.parse("testo\u{1B}").clean == "testo")
    }

    @Test func offsetsAreUTF16OnCleanText() {
        // "città" ha 5 unità UTF-16; lo span colorato inizia dopo.
        let result = ANSIParser.parse("città \u{1B}[35mviola\u{1B}[0m")
        #expect(result.clean == "città viola")
        #expect(result.spans == [ANSISpan(start: 6, length: 5, colorIndex: 5, bold: false)])
    }
}
