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
}
