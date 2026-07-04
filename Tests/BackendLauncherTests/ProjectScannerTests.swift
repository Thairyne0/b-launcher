import Foundation
import Testing
@testable import BackendLauncher

/// Fixture per `ProjectScanner`: ogni test costruisce la propria root in una directory
/// temporanea univoca (mai la vera Application Support, mai file reali dell'utente).
@Suite struct ProjectScannerTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try string.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - package.json

    @Test func packageJsonStartDevDetected() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("gateway")
        try write("""
        {
          "scripts": {
            "start:dev": "nest start --watch",
            "start": "nest start"
          }
        }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("APP_PORT=4000\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.count == 1)
        let service = try #require(result.services.first)
        #expect(service.name == "gateway")
        #expect(service.relativeDirectory == "gateway")
        #expect(service.command == "npm run start:dev")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 4000, marker: nil))
        #expect(service.sourceHint == "package.json (start:dev)")
    }

    @Test func packageJsonDevFallbackAndYarn() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("web")
        try write("""
        {
          "scripts": {
            "dev": "vite"
          }
        }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("", to: serviceDir.appendingPathComponent("yarn.lock"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.command == "yarn dev")
        #expect(service.sourceHint == "package.json (dev)")
    }

    @Test func pnpmLockUsesRunSyntax() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("api")
        try write("""
        {
          "scripts": {
            "serve": "node server.js"
          }
        }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("", to: serviceDir.appendingPathComponent("pnpm-lock.yaml"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.command == "pnpm run serve")
    }

    @Test func nestWithoutPortGetsLogMarker() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("nest-app")
        try write("""
        {
          "scripts": { "start": "nest start" },
          "dependencies": { "@nestjs/core": "^10.0.0" }
        }
        """, to: serviceDir.appendingPathComponent("package.json"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started"))
    }

    @Test func plainNodeWithoutPortGetsProcessAlive() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("plain-app")
        try write("""
        {
          "scripts": { "start": "node index.js" }
        }
        """, to: serviceDir.appendingPathComponent("package.json"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    // MARK: - go.mod / Cargo.toml

    @Test func goModDetected() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("goservice")
        try write("module example.com/goservice\n\ngo 1.22\n", to: serviceDir.appendingPathComponent("go.mod"))
        try write("PORT=8080\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.command == "go run .")
        #expect(service.sourceHint == "go.mod")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8080, marker: nil))
    }

    @Test func cargoTomlDetected() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("rustservice")
        try write("[package]\nname = \"rustservice\"\n", to: serviceDir.appendingPathComponent("Cargo.toml"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.command == "cargo run")
        #expect(service.sourceHint == "Cargo.toml")
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    // MARK: - Skipping rules

    @Test func skipsNodeModulesHiddenAndNoScript() throws {
        let root = try tempRoot()

        // node_modules: should be skipped even though it contains a package.json.
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("node_modules").appendingPathComponent("package.json"))

        // Hidden directory: should be skipped.
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent(".hidden").appendingPathComponent("package.json"))

        // No matching script: directory should be skipped entirely.
        try write("""
        { "scripts": { "test": "jest" } }
        """, to: root.appendingPathComponent("no-script").appendingPathComponent("package.json"))

        // .git, dist, build, vendor, target: should be skipped.
        for skipped in [".git", "dist", "build", "vendor", "target"] {
            try write("""
            { "scripts": { "start": "node index.js" } }
            """, to: root.appendingPathComponent(skipped).appendingPathComponent("package.json"))
        }

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.isEmpty)
    }

    // MARK: - docker-compose infra detection

    @Test func composeSuggestsInfra() throws {
        let root = try tempRoot()
        try write("""
        services:
          broker:
            image: nats:2.10
          app:
            build: .
        """, to: root.appendingPathComponent("docker-compose.yml"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.suggestedInfraCheck == StoredInfraCheck(label: "NATS", port: 4222))
    }

    @Test func composeSuggestsRedis() throws {
        let root = try tempRoot()
        try write("""
        services:
          cache:
            image: redis:7
        """, to: root.appendingPathComponent("compose.yml"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.suggestedInfraCheck == StoredInfraCheck(label: "Redis", port: 6379))
    }

    @Test func noComposeMeansNoInfraSuggestion() throws {
        let root = try tempRoot()
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("package.json"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.suggestedInfraCheck == nil)
    }

    // MARK: - Root-as-service / naming

    @Test func rootItselfAsService() throws {
        let root = try tempRoot()
        try write("""
        { "scripts": { "start:dev": "nest start" } }
        """, to: root.appendingPathComponent("package.json"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.count == 1)
        let service = try #require(result.services.first)
        #expect(service.relativeDirectory == "")
        #expect(service.name == root.lastPathComponent.lowercased())
        #expect(service.id == service.name)
        #expect(result.suggestedProjectName == root.lastPathComponent)
    }

    // MARK: - Ordering

    @Test func orderingStable() throws {
        let root = try tempRoot()
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("zeta").appendingPathComponent("package.json"))
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("alpha").appendingPathComponent("package.json"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.map(\.relativeDirectory) == ["alpha", "zeta"])
    }

    // MARK: - Port sniffing edge cases

    @Test func invalidPortIgnored() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("badport")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("PORT=99999\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    @Test func envPortKeyPriorityAppPortBeforePortBeforeServerPort() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("prio")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("SERVER_PORT=3002\nPORT=3001\nAPP_PORT=3000\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 3000, marker: nil))
    }
}
