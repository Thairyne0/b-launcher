import Testing
@testable import BackendLauncher

@MainActor
@Suite struct LogStoreTests {
    @Test func splitsChunksIntoLines() {
        let store = LogStore()
        store.ingest("hello\nwor")
        store.ingest("ld\n")
        #expect(store.lines.map(\.text) == ["hello", "world"])
    }

    @Test func flushPartialEmitsTrailingText() {
        let store = LogStore()
        store.ingest("no newline")
        #expect(store.lines.isEmpty)
        store.flushPartial()
        #expect(store.lines.map(\.text) == ["no newline"])
    }

    @Test func stripsANSIEscapes() {
        let store = LogStore()
        store.ingest("\u{1B}[32m[Nest] ready\u{1B}[0m\n")
        #expect(store.lines.map(\.text) == ["[Nest] ready"])
    }

    @Test func stripsOSCTitleSequenceTerminatedByBEL() {
        let store = LogStore()
        // OSC 0 ; <title> BEL — usata da molti tool per impostare il titolo del terminale.
        store.ingest("\u{1B}]0;my-title\u{07}hello\n")
        #expect(store.lines.map(\.text) == ["hello"])
    }

    @Test func stripsOSCSequenceTerminatedByST() {
        let store = LogStore()
        // OSC terminata da ST (ESC \) invece che BEL.
        store.ingest("\u{1B}]0;my-title\u{1B}\\hello\n")
        #expect(store.lines.map(\.text) == ["hello"])
    }

    @Test func stripsTrailingCarriageReturnFromCRLFLines() {
        let store = LogStore()
        store.ingest("hello\r\nworld\r\n")
        #expect(store.lines.map(\.text) == ["hello", "world"])
    }

    @Test func capsAtMaxLines() {
        let store = LogStore(maxLines: 3)
        store.ingest("1\n2\n3\n4\n5\n")
        #expect(store.lines.map(\.text) == ["3", "4", "5"])
    }

    @Test func idsKeepGrowingAfterCap() {
        let store = LogStore(maxLines: 2)
        store.ingest("a\nb\nc\n")
        #expect(store.lines.map(\.id) == [1, 2])
    }

    @Test func searchFiltersCaseInsensitive() {
        let store = LogStore()
        store.ingest("Nest started\nerror: boom\nlistening on 4000\n")
        store.searchText = "ERROR"
        #expect(store.visibleLines.map(\.text) == ["error: boom"])
        store.searchText = ""
        #expect(store.visibleLines.count == 3)
    }

    @Test func clearEmptiesLines() {
        let store = LogStore()
        store.ingest("x\n")
        store.clear()
        #expect(store.lines.isEmpty)
    }

    // MARK: - classify

    @Test func classifyNestErrorToken() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     ERROR [SomeContext] boom") == .error)
    }

    @Test func classifyNestFatalToken() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     FATAL [SomeContext] boom") == .error)
    }

    @Test func classifyNestWarnToken() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     WARN [SomeContext] careful") == .warning)
    }

    @Test func classifyNestDebugToken() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     DEBUG [SomeContext] detail") == .debug)
    }

    @Test func classifyNestVerboseToken() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     VERBOSE [SomeContext] chatter") == .debug)
    }

    @Test func classifyNestLogTokenIsNormal() {
        #expect(LogStore.classify("[Nest] 12345  - 03/07/2026, 14:23:45     LOG [SomeContext] all good") == .normal)
    }

    @Test func classifyNpmErrBang() {
        #expect(LogStore.classify("npm ERR! code ELIFECYCLE") == .error)
    }

    @Test func classifyLauncherLineMentioningErroreIsNormal() {
        #expect(LogStore.classify("[launcher] c'è stato un errore ma è solo testo") == .normal)
    }

    @Test func classifyPlainLineIsNormal() {
        #expect(LogStore.classify("just some plain output") == .normal)
    }

    // MARK: - errorCount

    @Test func errorCountIncrementsOnErrorLines() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] fine\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.ingest("npm ERR! failed\n")
        #expect(store.errorCount == 2)
    }

    @Test func errorCountResetsOnClear() {
        let store = LogStore()
        store.ingest("npm ERR! failed\n")
        #expect(store.errorCount == 1)
        store.clear()
        #expect(store.errorCount == 0)
    }

    @Test func errorCountResetsOnLauncherStartBanner() {
        let store = LogStore()
        store.ingest("npm ERR! failed\n")
        #expect(store.errorCount == 1)
        store.ingest("[launcher] ── avvio ──\n")
        #expect(store.errorCount == 0)
    }

    @Test func resetErrorCountClearsCounter() {
        let store = LogStore()
        store.ingest("npm ERR! failed\n")
        #expect(store.errorCount == 1)
        store.resetErrorCount()
        #expect(store.errorCount == 0)
    }

    // MARK: - levelFilter

    @Test func levelFilterErrorsOnlyShowsErrors() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] fine\n")
        store.ingest("[Nest] 1  - now     WARN [X] careful\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.levelFilter = .errors
        #expect(store.visibleLines.map(\.text) == ["[Nest] 1  - now     ERROR [X] boom"])
    }

    @Test func levelFilterWarnPlusShowsWarningsAndErrors() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] fine\n")
        store.ingest("[Nest] 1  - now     WARN [X] careful\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.levelFilter = .warnPlus
        #expect(store.visibleLines.map(\.text) == [
            "[Nest] 1  - now     WARN [X] careful",
            "[Nest] 1  - now     ERROR [X] boom",
        ])
    }

    @Test func levelFilterAllShowsEverything() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] fine\n")
        store.ingest("[Nest] 1  - now     WARN [X] careful\n")
        store.levelFilter = .all
        #expect(store.visibleLines.count == 2)
    }

    @Test func levelFilterCombinesWithSearchText() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     WARN [X] careful boom\n")
        store.ingest("[Nest] 1  - now     WARN [X] careful other\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.levelFilter = .warnPlus
        store.searchText = "boom"
        #expect(store.visibleLines.map(\.text) == [
            "[Nest] 1  - now     WARN [X] careful boom",
            "[Nest] 1  - now     ERROR [X] boom",
        ])
    }

    // MARK: - errorBlock

    @Test func errorBlockCapturesFollowingStackLines() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.ingest("    at someFunction (file.js:10:5)\n")
        store.ingest("    at anotherFunction (file.js:20:5)\n")
        store.ingest("[Nest] 1  - now     LOG [X] recovered\n")
        let block = LogStore.errorBlock(startingAt: 0, in: store.lines)
        #expect(block == """
        [Nest] 1  - now     ERROR [X] boom
            at someFunction (file.js:10:5)
            at anotherFunction (file.js:20:5)
        """)
    }

    @Test func errorBlockAtEndOfBufferIsSingleLine() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] fine\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        let block = LogStore.errorBlock(startingAt: 1, in: store.lines)
        #expect(block == "[Nest] 1  - now     ERROR [X] boom")
    }

    @Test func errorBlockStopsAtNonStackNormalLine() {
        let store = LogStore()
        store.ingest("npm ERR! failed\n")
        store.ingest("at something.js:1:1\n")
        store.ingest("not indented and not at-prefixed\n")
        store.ingest("    still indented but after break\n")
        let block = LogStore.errorBlock(startingAt: 0, in: store.lines)
        #expect(block == """
        npm ERR! failed
        at something.js:1:1
        """)
    }

    @Test func errorBlockStopsAtSubsequentErrorOrWarningLine() {
        let store = LogStore()
        store.ingest("npm ERR! failed\n")
        store.ingest("    at something.js:1:1\n")
        store.ingest("[Nest] 1  - now     WARN [X] careful\n")
        let block = LogStore.errorBlock(startingAt: 0, in: store.lines)
        #expect(block == """
        npm ERR! failed
            at something.js:1:1
        """)
    }

    // MARK: - searchMode

    @Test func highlightModeKeepsAllLines() {
        let store = LogStore()
        store.ingest("hello\nworld\nfoo\n")
        store.searchText = "world"
        store.searchMode = .highlight
        #expect(store.visibleLines.count == 3)
        store.searchMode = .filter
        #expect(store.visibleLines.count == 1)
    }

    @Test func searchMatchIDsFindsMatches() {
        let store = LogStore()
        store.ingest("hello\nWORLD\nfoo\n")
        store.searchText = "world"
        #expect(store.searchMatchIDs == [1])
        store.searchText = ""
        #expect(store.searchMatchIDs == [])
    }

    @Test func searchMatchIDsRespectsLevelFilter() {
        let store = LogStore()
        store.ingest("[Nest] 1  - now     LOG [X] boom fine\n")
        store.ingest("[Nest] 1  - now     ERROR [X] boom\n")
        store.levelFilter = .errors
        store.searchText = "boom"
        #expect(store.searchMatchIDs == [1])
    }
}
