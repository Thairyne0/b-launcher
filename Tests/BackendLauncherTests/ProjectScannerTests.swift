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

    // MARK: - .env quoted values (B2)

    @Test func envPortDoubleQuoted() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("quoted-double")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("PORT=\"3000\"\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 3000, marker: nil))
    }

    @Test func envPortSingleQuoted() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("quoted-single")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("PORT='8080'\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8080, marker: nil))
    }

    @Test func envPortUnquotedWithInlineComment() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("unquoted-comment")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("PORT=3000 # web\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 3000, marker: nil))
    }

    @Test func envPortQuotedWithCommentAfter() throws {
        let root = try tempRoot()
        let serviceDir = root.appendingPathComponent("quoted-comment")
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: serviceDir.appendingPathComponent("package.json"))
        try write("PORT=\"3000\" # web\n", to: serviceDir.appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let service = try #require(result.services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 3000, marker: nil))
    }

    // MARK: - Duplicate-port downgrade (B3)

    @Test func duplicatePortDowngradesSecondService() throws {
        let root = try tempRoot()
        // "alpha" sorts before "beta": alpha keeps .port, beta (same port) is downgraded.
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("alpha").appendingPathComponent("package.json"))
        try write("PORT=4000\n", to: root.appendingPathComponent("alpha").appendingPathComponent(".env"))

        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("beta").appendingPathComponent("package.json"))
        try write("PORT=4000\n", to: root.appendingPathComponent("beta").appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.count == 2)
        let alpha = try #require(result.services.first { $0.relativeDirectory == "alpha" })
        let beta = try #require(result.services.first { $0.relativeDirectory == "beta" })

        #expect(alpha.readiness == StoredReadiness(kind: .port, port: 4000, marker: nil))
        #expect(beta.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
        #expect(beta.sourceHint.hasSuffix(" — porta 4000 duplicata"))
        #expect(beta.sourceHint.hasPrefix("package.json"))
    }

    @Test func duplicatePortDowngradesToNestLogMarkerWhenApplicable() throws {
        let root = try tempRoot()
        try write("""
        { "scripts": { "start": "node index.js" } }
        """, to: root.appendingPathComponent("alpha").appendingPathComponent("package.json"))
        try write("PORT=5000\n", to: root.appendingPathComponent("alpha").appendingPathComponent(".env"))

        try write("""
        {
          "scripts": { "start": "nest start" },
          "dependencies": { "@nestjs/core": "^10.0.0" }
        }
        """, to: root.appendingPathComponent("beta-nest").appendingPathComponent("package.json"))
        try write("PORT=5000\n", to: root.appendingPathComponent("beta-nest").appendingPathComponent(".env"))

        let result = ProjectScanner.scan(root: root)

        let betaNest = try #require(result.services.first { $0.relativeDirectory == "beta-nest" })
        #expect(betaNest.readiness == StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started"))
        #expect(betaNest.sourceHint.hasSuffix(" — porta 5000 duplicata"))
    }

    // MARK: - Python

    @Test func managePyDetectedAsDjango() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("backend-py")
        try write("#!/usr/bin/env python\n", to: dir.appendingPathComponent("manage.py"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "python manage.py runserver")
        #expect(service.sourceHint == "manage.py (Django)")
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    @Test func pyprojectFastapiUsesUvicorn() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("api-py")
        try write("[project]\ndependencies = [\"fastapi\", \"uvicorn\"]\n",
                  to: dir.appendingPathComponent("pyproject.toml"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "uvicorn main:app --reload")
        #expect(service.sourceHint == "pyproject.toml (FastAPI)")
    }

    @Test func requirementsFlaskUsesFlaskRun() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("web-py")
        try write("Flask==3.0\n", to: dir.appendingPathComponent("requirements.txt"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "flask run")
        #expect(service.sourceHint == "requirements.txt (Flask)")
    }

    @Test func genericPythonNeedsMainPy() throws {
        let root = try tempRoot()
        let withMain = root.appendingPathComponent("worker")
        try write("requests\n", to: withMain.appendingPathComponent("requirements.txt"))
        try write("print('hi')\n", to: withMain.appendingPathComponent("main.py"))
        let withoutMain = root.appendingPathComponent("lib-only")
        try write("requests\n", to: withoutMain.appendingPathComponent("requirements.txt"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.count == 1)
        let service = try #require(result.services.first)
        #expect(service.relativeDirectory == "worker")
        #expect(service.command == "python main.py")
        #expect(service.sourceHint == "requirements.txt")
    }

    @Test func pythonReadinessUsesEnvPort() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("api-py")
        try write("fastapi\n", to: dir.appendingPathComponent("requirements.txt"))
        try write("PORT=8001\n", to: dir.appendingPathComponent(".env"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8001, marker: nil))
    }

    @Test func packageJsonTakesPrecedenceOverPython() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("hybrid")
        try write("{ \"scripts\": { \"dev\": \"vite\" } }", to: dir.appendingPathComponent("package.json"))
        try write("#!/usr/bin/env python\n", to: dir.appendingPathComponent("manage.py"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "npm run dev")
    }

    // MARK: - Java / Spring

    @Test func mavenSpringBootPrefersWrapper() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("spring-api")
        try write("<project><artifactId>spring-boot-starter-parent</artifactId></project>",
                  to: dir.appendingPathComponent("pom.xml"))
        try write("#!/bin/sh\n", to: dir.appendingPathComponent("mvnw"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "./mvnw spring-boot:run")
        #expect(service.sourceHint == "pom.xml (Spring Boot)")
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    @Test func mavenSpringBootWithoutWrapperUsesMvn() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("spring-api")
        try write("<project>spring-boot</project>", to: dir.appendingPathComponent("pom.xml"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "mvn spring-boot:run")
    }

    @Test func gradleSpringBootUsesBootRun() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("spring-gradle")
        try write("plugins { id 'org.springframework.boot' version '3.2.0' }",
                  to: dir.appendingPathComponent("build.gradle"))
        try write("#!/bin/sh\n", to: dir.appendingPathComponent("gradlew"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "./gradlew bootRun")
        #expect(service.sourceHint == "build.gradle (Spring Boot)")
    }

    @Test func nonSpringJavaIsSkipped() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("java-lib")
        try write("<project><artifactId>commons-utils</artifactId></project>",
                  to: dir.appendingPathComponent("pom.xml"))

        #expect(ProjectScanner.scan(root: root).services.isEmpty)
    }

    // MARK: - PHP

    @Test func laravelArtisanDetected() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("laravel-app")
        try write("<?php // artisan\n", to: dir.appendingPathComponent("artisan"))
        try write("{}", to: dir.appendingPathComponent("composer.json"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "php artisan serve")
        #expect(service.sourceHint == "artisan (Laravel)")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8000, marker: nil))
    }

    @Test func plainPhpWithIndexUsesBuiltinServer() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("php-site")
        try write("{}", to: dir.appendingPathComponent("composer.json"))
        try write("<?php echo 'ciao';\n", to: dir.appendingPathComponent("index.php"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "php -S localhost:8080")
        #expect(service.sourceHint == "composer.json")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8080, marker: nil))
    }

    @Test func composerWithoutIndexIsSkipped() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("php-lib")
        try write("{}", to: dir.appendingPathComponent("composer.json"))

        #expect(ProjectScanner.scan(root: root).services.isEmpty)
    }

    // MARK: - docker-compose (servizi)

    @Test func composeServicesDetectedInfraExcluded() throws {
        let root = try tempRoot()
        try write("""
        services:
          app:
            build: .
            ports:
              - "8080:80"
          nats:
            image: nats:2
            ports:
              - "4222:4222"
        """, to: root.appendingPathComponent("docker-compose.yml"))

        let result = ProjectScanner.scan(root: root)

        #expect(result.services.count == 1)
        let service = try #require(result.services.first)
        #expect(service.name == "app")
        #expect(service.relativeDirectory == "")
        #expect(service.command == "docker compose up app")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 8080, marker: nil))
        #expect(service.sourceHint == "docker-compose.yml (app)")
        // La spia infrastruttura continua a suggerire NATS.
        #expect(result.suggestedInfraCheck == StoredInfraCheck(label: "NATS", port: 4222))
    }

    @Test func composeInfraExcludedByImageToo() throws {
        let root = try tempRoot()
        try write("""
        services:
          cache:
            image: redis:7
        """, to: root.appendingPathComponent("docker-compose.yml"))

        #expect(ProjectScanner.scan(root: root).services.isEmpty)
    }

    @Test func composeCustomFileNameUsesDashF() throws {
        let root = try tempRoot()
        try write("""
        services:
          app:
            build: .
        """, to: root.appendingPathComponent("docker-compose.dev.yml"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.command == "docker compose -f docker-compose.dev.yml up app")
        #expect(service.readiness == StoredReadiness(kind: .processAlive, port: nil, marker: nil))
    }

    @Test func composeHostPortWithBindAddressParsed() throws {
        let root = try tempRoot()
        try write("""
        services:
          app:
            ports:
              - "127.0.0.1:9090:80"
        """, to: root.appendingPathComponent("compose.yml"))

        let service = try #require(ProjectScanner.scan(root: root).services.first)
        #expect(service.readiness == StoredReadiness(kind: .port, port: 9090, marker: nil))
        #expect(service.command == "docker compose up app")
    }
}
