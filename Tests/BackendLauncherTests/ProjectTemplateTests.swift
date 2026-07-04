import Foundation
import Testing
@testable import BackendLauncher

@Suite struct ProjectTemplateCodecTests {
    private func service(_ name: String, _ directory: String, port: UInt16? = nil) -> StoredService {
        StoredService(
            name: name,
            directory: directory,
            command: "npm run start:dev",
            readiness: port.map { StoredReadiness(kind: .port, port: $0, marker: nil) }
                ?? StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started")
        )
    }

    @Test func roundTripRelativePaths() throws {
        let root = URL(fileURLWithPath: "/Users/dev/Skillera")
        let project = StoredProject(
            name: "Skillera",
            services: [
                service("gateway", "/Users/dev/Skillera/SKILLGATEWAY-BE", port: 4000),
                service("id", "/Users/dev/Skillera/SKILLID-BE", port: 4001),
            ],
            profiles: [StoredProfile(name: "Tutti", serviceNames: ["gateway", "id"])],
            infraCheck: StoredInfraCheck(label: "NATS", port: 4222)
        )

        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)

        #expect(template.templateVersion == 1)
        #expect(template.name == "Skillera")
        #expect(template.services.count == 2)
        for templateService in template.services {
            #expect(!templateService.relativeDirectory.hasPrefix("/"))
            #expect(!templateService.relativeDirectory.hasPrefix(ProjectTemplateCodec.absoluteMarkerPrefix))
        }
        let gateway = try #require(template.services.first { $0.name == "gateway" })
        #expect(gateway.relativeDirectory == "SKILLGATEWAY-BE")

        // makeProject su una root DIVERSA deve ribasare correttamente i path.
        let newRoot = URL(fileURLWithPath: "/Users/colleague/repos/Skillera")
        let rebuilt = try ProjectTemplateCodec.makeProject(from: template, root: newRoot, nameOverride: nil)

        #expect(rebuilt.name == "Skillera")
        let rebuiltGateway = try #require(rebuilt.services.first { $0.name == "gateway" })
        #expect(rebuiltGateway.directory == "/Users/colleague/repos/Skillera/SKILLGATEWAY-BE")
        let rebuiltID = try #require(rebuilt.services.first { $0.name == "id" })
        #expect(rebuiltID.directory == "/Users/colleague/repos/Skillera/SKILLID-BE")
        #expect(rebuilt.profiles == project.profiles)
        #expect(rebuilt.infraCheck == project.infraCheck)
    }

    @Test func serviceOutsideRootGetsAbsMarkerAndRebasesAsIsOnImport() throws {
        let root = URL(fileURLWithPath: "/Users/dev/Skillera")
        let project = StoredProject(
            name: "Mixed",
            services: [
                service("inside", "/Users/dev/Skillera/inside-service"),
                service("outside", "/opt/shared/outside-service"),
            ],
            profiles: [],
            infraCheck: nil
        )

        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)

        let insideEntry = try #require(template.services.first { $0.name == "inside" })
        #expect(insideEntry.relativeDirectory == "inside-service")

        let outsideEntry = try #require(template.services.first { $0.name == "outside" })
        #expect(outsideEntry.relativeDirectory == ProjectTemplateCodec.absoluteMarkerPrefix + "/opt/shared/outside-service")

        // Import su una root differente: l'entry "abs:" resta assoluta as-is, non viene ribasata.
        let newRoot = URL(fileURLWithPath: "/Users/colleague/repos/Mixed")
        let rebuilt = try ProjectTemplateCodec.makeProject(from: template, root: newRoot, nameOverride: nil)

        let rebuiltInside = try #require(rebuilt.services.first { $0.name == "inside" })
        #expect(rebuiltInside.directory == "/Users/colleague/repos/Mixed/inside-service")

        let rebuiltOutside = try #require(rebuilt.services.first { $0.name == "outside" })
        #expect(rebuiltOutside.directory == "/opt/shared/outside-service")
    }

    @Test func decodeRejectsFutureTemplateVersion() throws {
        let future = ProjectTemplate(
            templateVersion: 99,
            name: "Future",
            services: [],
            profiles: [],
            infraCheck: nil
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(future)

        #expect(throws: ProjectTemplateError.self) {
            try ProjectTemplateCodec.decode(data)
        }
    }

    @Test func encodeDecodeRoundTrip() throws {
        let root = URL(fileURLWithPath: "/Users/dev/Skillera")
        let project = StoredProject(
            name: "Skillera",
            services: [service("gateway", "/Users/dev/Skillera/SKILLGATEWAY-BE", port: 4000)],
            profiles: [StoredProfile(name: "Tutti", serviceNames: ["gateway"])],
            infraCheck: StoredInfraCheck(label: "NATS", port: 4222)
        )
        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)

        let data = try ProjectTemplateCodec.encode(template)
        let decoded = try ProjectTemplateCodec.decode(data)

        #expect(decoded.name == template.name)
        #expect(decoded.services.count == template.services.count)
        #expect(decoded.templateVersion == 1)
    }

    @Test func envBadgeDisabledSurvivesTemplateRoundTrip() throws {
        let root = URL(fileURLWithPath: "/Users/dev/proj")
        var stored = service("no-env", "/Users/dev/proj/no-env")
        stored.envBadgeDisabled = true
        let project = StoredProject(name: "P", services: [stored], profiles: [], infraCheck: nil)

        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)
        let data = try ProjectTemplateCodec.encode(template)
        let decoded = try ProjectTemplateCodec.decode(data)
        let rebuilt = try ProjectTemplateCodec.makeProject(from: decoded, root: root, nameOverride: nil)

        #expect(rebuilt.services.first?.envBadgeDisabled == true)
    }

    @Test func commonRootComputesSharedParentDirectory() throws {
        let common = ProjectTemplateCodec.commonRoot(forServiceDirectories: [
            "/Users/dev/Skillera/SKILLGATEWAY-BE",
            "/Users/dev/Skillera/SKILLID-BE",
            "/Users/dev/Skillera/SKILLATLAS-BE",
        ])
        #expect(common?.path == "/Users/dev/Skillera")
    }

    @Test func commonRootReturnsNilWhenNoSharedAncestor() throws {
        let common = ProjectTemplateCodec.commonRoot(forServiceDirectories: [
            "/Users/dev/one",
            "/opt/other",
        ])
        #expect(common == nil)
    }

    @Test func commonRootReturnsNilForEmptyList() throws {
        #expect(ProjectTemplateCodec.commonRoot(forServiceDirectories: []) == nil)
    }

    @Test func makeProjectAppliesNameOverride() throws {
        let root = URL(fileURLWithPath: "/Users/dev/Skillera")
        let project = StoredProject(name: "Skillera", services: [service("gateway", "/Users/dev/Skillera/GW")],
                                    profiles: [], infraCheck: nil)
        let template = ProjectTemplateCodec.makeTemplate(from: project, root: root)

        let rebuilt = try ProjectTemplateCodec.makeProject(from: template, root: root, nameOverride: "Skillera (colleague)")
        #expect(rebuilt.name == "Skillera (colleague)")
    }

    @Test func makeProjectRejectsParentTraversalPaths() throws {
        // Template artigianale con "..": non deve poter risolvere fuori dalla root scelta.
        let template = ProjectTemplate(
            templateVersion: 1,
            name: "Evil",
            services: [ProjectTemplate.TemplateService(
                name: "svc",
                relativeDirectory: "../../etc",
                command: "true",
                readiness: StoredReadiness(kind: .processAlive, port: nil, marker: nil)
            )],
            profiles: [],
            infraCheck: nil
        )
        #expect(throws: ProjectTemplateError.unsafeRelativePath("../../etc")) {
            _ = try ProjectTemplateCodec.makeProject(from: template,
                                                     root: URL(fileURLWithPath: "/tmp/root"),
                                                     nameOverride: nil)
        }
    }
}
