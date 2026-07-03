import Testing
@testable import BackendLauncher

@Suite struct FocusSelectionTests {
    @Test func parseEmptyString() {
        #expect(FocusSelection.parse("") == [])
    }

    @Test func parseSingleName() {
        #expect(FocusSelection.parse("gateway") == ["gateway"])
    }

    @Test func parseMultipleNames() {
        #expect(FocusSelection.parse("gateway,id,atlas") == ["gateway", "id", "atlas"])
    }

    @Test func parseIgnoresEmptySegments() {
        #expect(FocusSelection.parse("gateway,,id,") == ["gateway", "id"])
    }

    @Test func serializeRespectsOrdering() {
        let names: Set<String> = ["id", "gateway", "bill"]
        let ordering = ["gateway", "id", "atlas", "hr", "certet", "bill"]
        #expect(FocusSelection.serialize(names, ordering: ordering) == "gateway,id,bill")
    }

    @Test func serializeDropsNamesNotInOrdering() {
        let names: Set<String> = ["gateway", "unknown"]
        let ordering = ["gateway", "id"]
        #expect(FocusSelection.serialize(names, ordering: ordering) == "gateway")
    }

    @Test func serializeEmptySetIsEmptyString() {
        #expect(FocusSelection.serialize([], ordering: ["gateway", "id"]) == "")
    }

    @Test func roundTripPreservesOrderStableSerialization() {
        let ordering = ServiceConfig.all.map(\.name)
        let raw = "bill,gateway,hr"
        let parsed = FocusSelection.parse(raw)
        let reserialized = FocusSelection.serialize(parsed, ordering: ordering)
        #expect(reserialized == "gateway,hr,bill")
    }
}
