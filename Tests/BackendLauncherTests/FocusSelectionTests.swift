import SwiftUI
import Testing
@testable import BackendLauncher

@Suite struct ColorHexTests {
    @Test func parsesValidHexWithHash() {
        #expect(Color(hex: "#4F8EF7") != nil)
    }

    @Test func parsesValidHexWithoutHash() {
        #expect(Color(hex: "4F8EF7") != nil)
    }

    @Test func rejectsInvalidLength() {
        #expect(Color(hex: "#FFF") == nil)
        #expect(Color(hex: "#4F8EF70") == nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(Color(hex: "#GGGGGG") == nil)
    }
}

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

    // MARK: - migrate (Phase D: bare-name -> namespaced id)

    @Test func migrateResolvesBareNameToUniqueNamespacedID() {
        let services = [
            ServiceConfig(name: "gateway", directory: "", port: 4000, projectName: "Skillera"),
            ServiceConfig(name: "id", directory: "", port: 4001, projectName: "Skillera"),
        ]
        let migrated = FocusSelection.migrate(["gateway"], services: services)
        #expect(migrated == ["Skillera/gateway"])
    }

    @Test func migrateDropsAmbiguousBareNameAcrossProjects() {
        let services = [
            ServiceConfig(name: "gateway", directory: "", port: 4000, projectName: "ProjA"),
            ServiceConfig(name: "gateway", directory: "", port: 5000, projectName: "ProjB"),
        ]
        let migrated = FocusSelection.migrate(["gateway"], services: services)
        #expect(migrated.isEmpty)
    }

    @Test func migrateDropsBareNameWithNoMatch() {
        let services = [ServiceConfig(name: "gateway", directory: "", port: 4000, projectName: "Skillera")]
        let migrated = FocusSelection.migrate(["does-not-exist"], services: services)
        #expect(migrated.isEmpty)
    }

    @Test func migratePassesThroughAlreadyNamespacedIDs() {
        let services = [ServiceConfig(name: "gateway", directory: "", port: 4000, projectName: "Skillera")]
        let migrated = FocusSelection.migrate(["Skillera/gateway"], services: services)
        #expect(migrated == ["Skillera/gateway"])
    }

    @Test func migrateHandlesMixOfBareAndNamespacedTokens() {
        let services = [
            ServiceConfig(name: "gateway", directory: "", port: 4000, projectName: "Skillera"),
            ServiceConfig(name: "id", directory: "", port: 4001, projectName: "Skillera"),
        ]
        let migrated = FocusSelection.migrate(["gateway", "Skillera/id"], services: services)
        #expect(migrated == ["Skillera/gateway", "Skillera/id"])
    }
}

@Suite struct SidebarSelectionCodingTests {
    @Test func encodeGrid() {
        #expect(SidebarSelectionCoding.encode(.grid) == "grid")
    }

    @Test func encodeFocus() {
        #expect(SidebarSelectionCoding.encode(.focus) == "focus")
    }

    @Test func encodeDecodeErrors() {
        #expect(SidebarSelectionCoding.encode(.errors) == "errors")
        #expect(SidebarSelectionCoding.decode("errors") == .errors)
    }

    @Test func encodeService() {
        #expect(SidebarSelectionCoding.encode(.service("gateway")) == "service:gateway")
    }

    @Test func decodeGrid() {
        #expect(SidebarSelectionCoding.decode("grid") == .grid)
    }

    @Test func decodeFocus() {
        #expect(SidebarSelectionCoding.decode("focus") == .focus)
    }

    @Test func decodeService() {
        #expect(SidebarSelectionCoding.decode("service:gateway") == .service("gateway"))
    }

    @Test func decodeUnknownFallsBackToGrid() {
        #expect(SidebarSelectionCoding.decode("bogus") == .grid)
        #expect(SidebarSelectionCoding.decode("") == .grid)
        #expect(SidebarSelectionCoding.decode("service:") == .grid)
    }

    @Test func roundTripPreservesSelection() {
        let selections: [SidebarSelection] = [.grid, .focus, .service("id"), .service("gateway"), .project("Skillera")]
        for selection in selections {
            let encoded = SidebarSelectionCoding.encode(selection)
            #expect(SidebarSelectionCoding.decode(encoded) == selection)
        }
    }

    // MARK: - project case

    @Test func encodeProject() {
        #expect(SidebarSelectionCoding.encode(.project("Skillera")) == "project:Skillera")
    }

    @Test func decodeProject() {
        #expect(SidebarSelectionCoding.decode("project:Skillera") == .project("Skillera"))
    }

    @Test func decodeEmptyProjectIDFallsBackToGrid() {
        #expect(SidebarSelectionCoding.decode("project:") == .grid)
    }

    @Test func roundTripPreservesProjectSelection() {
        let selection = SidebarSelection.project("MyProject")
        #expect(SidebarSelectionCoding.decode(SidebarSelectionCoding.encode(selection)) == selection)
    }
}
