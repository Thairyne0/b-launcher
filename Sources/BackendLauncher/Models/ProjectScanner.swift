import Foundation

/// Scansione deterministica di una cartella progetto: individua servizi avviabili
/// e propone nome/comando/readiness. Nessuna rete, nessuna AI — solo convenzioni.
enum ProjectScanner {
    struct ScannedService: Equatable, Identifiable {
        var name: String              // nome cartella, lowercased
        var relativeDirectory: String // relativo alla root ("" = root stessa)
        var command: String
        var readiness: StoredReadiness
        var sourceHint: String        // es. "package.json (start:dev)", "go.mod", "Cargo.toml"
        var id: String { relativeDirectory.isEmpty ? name : relativeDirectory }
    }

    struct ScanResult: Equatable {
        var services: [ScannedService]
        var suggestedInfraCheck: StoredInfraCheck?  // da docker-compose
        var suggestedProjectName: String            // nome cartella root
    }

    /// Risultato intermedio di `scanService`: porta con sé `hasNestDependency`, necessario
    /// per scegliere il fallback corretto se il servizio viene retrocesso per porta duplicata
    /// (vedi `downgradeDuplicatePorts`), senza dover ripetere il parsing di package.json.
    private struct ScannedServiceCandidate {
        var service: ScannedService
        var hasNestDependency: Bool
    }

    /// Nomi di directory sempre esclusi dalla scansione (di primo livello o come radice
    /// di un servizio candidato), oltre a qualunque directory nascosta (prefisso ".").
    private static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", "dist", "build", "vendor", "target",
    ]

    /// Script di package.json in ordine di priorità: il primo presente vince.
    private static let npmScriptPriority = ["start:dev", "dev", "serve", "start"]

    /// Chiavi da cercare in un file `.env`, in ordine di priorità.
    private static let envPortKeys = ["APP_PORT", "PORT", "SERVER_PORT"]

    /// Mappa (substring cercata nel testo del compose file) -> infra check suggerito.
    /// L'ordine determina la priorità in caso di più match nello stesso file.
    private static let infraSignatures: [(needle: String, check: StoredInfraCheck)] = [
        ("nats", StoredInfraCheck(label: "NATS", port: 4222)),
        ("redis", StoredInfraCheck(label: "Redis", port: 6379)),
        ("postgres", StoredInfraCheck(label: "Postgres", port: 5432)),
        ("mongo", StoredInfraCheck(label: "MongoDB", port: 27017)),
        ("rabbitmq", StoredInfraCheck(label: "RabbitMQ", port: 5672)),
    ]

    private static let composeFileNames: Set<String> = [
        "docker-compose.yml", "compose.yml",
    ]

    static func scan(root: URL) -> ScanResult {
        let fileManager = FileManager.default
        let standardizedRoot = root.standardizedFileURL

        var candidateDirectories: [URL] = [standardizedRoot]
        if let entries = try? fileManager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard !name.hasPrefix("."), !excludedDirectoryNames.contains(name) else { continue }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                candidateDirectories.append(entry.standardizedFileURL)
            }
        }

        var scanned: [ScannedServiceCandidate] = []
        for directory in candidateDirectories {
            guard let candidate = scanService(in: directory, root: standardizedRoot) else { continue }
            scanned.append(candidate)
        }
        scanned.sort { $0.service.relativeDirectory < $1.service.relativeDirectory }

        // Servizi docker-compose DOPO quelli su directory (e quindi perdenti in caso di
        // porta duplicata: la readiness a porta resta al servizio "nativo").
        scanned.append(contentsOf: scanComposeServices(in: standardizedRoot))

        let services = downgradeDuplicatePorts(scanned)

        let suggestedInfraCheck = scanComposeInfra(in: standardizedRoot)

        return ScanResult(
            services: services,
            suggestedInfraCheck: suggestedInfraCheck,
            suggestedProjectName: standardizedRoot.lastPathComponent
        )
    }

    // MARK: - Per-directory detection

    private static func scanService(in directory: URL, root: URL) -> ScannedServiceCandidate? {
        let fileManager = FileManager.default
        let relativeDirectory = relativePath(of: directory, root: root)
        let name = (relativeDirectory.isEmpty ? root.lastPathComponent : directory.lastPathComponent).lowercased()

        let packageJSONURL = directory.appendingPathComponent("package.json")
        if fileManager.fileExists(atPath: packageJSONURL.path) {
            return scanNodeService(
                packageJSONURL: packageJSONURL,
                directory: directory,
                relativeDirectory: relativeDirectory,
                name: name
            )
        }

        let goModURL = directory.appendingPathComponent("go.mod")
        if fileManager.fileExists(atPath: goModURL.path) {
            let service = ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: "go run .",
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: "go.mod"
            )
            return ScannedServiceCandidate(service: service, hasNestDependency: false)
        }

        let cargoTomlURL = directory.appendingPathComponent("Cargo.toml")
        if fileManager.fileExists(atPath: cargoTomlURL.path) {
            let service = ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: "cargo run",
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: "Cargo.toml"
            )
            return ScannedServiceCandidate(service: service, hasNestDependency: false)
        }

        if let python = scanPythonService(in: directory, relativeDirectory: relativeDirectory, name: name) {
            return python
        }
        if let java = scanSpringService(in: directory, relativeDirectory: relativeDirectory, name: name) {
            return java
        }
        if let php = scanPHPService(in: directory, relativeDirectory: relativeDirectory, name: name) {
            return php
        }

        return nil
    }

    // MARK: - Python / Java / PHP

    /// Python per convenzioni: `manage.py` (Django), altrimenti pyproject/requirements con
    /// framework riconoscibile (FastAPI → uvicorn, Flask → flask run), altrimenti `main.py`
    /// generico. Una cartella con soli requirements e nessun entrypoint non è un backend.
    private static func scanPythonService(in directory: URL, relativeDirectory: String, name: String) -> ScannedServiceCandidate? {
        let fileManager = FileManager.default
        func make(_ command: String, _ hint: String) -> ScannedServiceCandidate {
            let service = ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: command,
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: hint
            )
            return ScannedServiceCandidate(service: service, hasNestDependency: false)
        }

        if fileManager.fileExists(atPath: directory.appendingPathComponent("manage.py").path) {
            return make("python manage.py runserver", "manage.py (Django)")
        }

        for manifest in ["pyproject.toml", "requirements.txt"] {
            let url = directory.appendingPathComponent(manifest)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lowercased = text.lowercased()
            if lowercased.contains("fastapi") {
                return make("uvicorn main:app --reload", "\(manifest) (FastAPI)")
            }
            if lowercased.contains("flask") {
                return make("flask run", "\(manifest) (Flask)")
            }
            if fileManager.fileExists(atPath: directory.appendingPathComponent("main.py").path) {
                return make("python main.py", manifest)
            }
        }
        return nil
    }

    /// Java solo se Spring Boot (un pom/gradle generico è spesso una libreria, non un
    /// backend avviabile). Preferisce il wrapper del progetto (mvnw/gradlew) se presente.
    private static func scanSpringService(in directory: URL, relativeDirectory: String, name: String) -> ScannedServiceCandidate? {
        let fileManager = FileManager.default
        func make(_ command: String, _ hint: String) -> ScannedServiceCandidate {
            let service = ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: command,
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: hint
            )
            return ScannedServiceCandidate(service: service, hasNestDependency: false)
        }

        let pomURL = directory.appendingPathComponent("pom.xml")
        if let pom = try? String(contentsOf: pomURL, encoding: .utf8),
           pom.lowercased().contains("spring-boot") {
            let hasWrapper = fileManager.fileExists(atPath: directory.appendingPathComponent("mvnw").path)
            return make(hasWrapper ? "./mvnw spring-boot:run" : "mvn spring-boot:run",
                        "pom.xml (Spring Boot)")
        }

        for gradleFile in ["build.gradle", "build.gradle.kts"] {
            let url = directory.appendingPathComponent(gradleFile)
            guard let gradle = try? String(contentsOf: url, encoding: .utf8),
                  gradle.lowercased().contains("springframework") || gradle.lowercased().contains("spring-boot") else { continue }
            let hasWrapper = fileManager.fileExists(atPath: directory.appendingPathComponent("gradlew").path)
            return make(hasWrapper ? "./gradlew bootRun" : "gradle bootRun",
                        "\(gradleFile) (Spring Boot)")
        }
        return nil
    }

    /// PHP: `artisan` (Laravel, `serve` di default su 8000), altrimenti composer.json +
    /// index.php col server built-in su 8080. Le porte sono quelle imposte dal COMANDO
    /// suggerito, quindi coerenti con la readiness per costruzione.
    private static func scanPHPService(in directory: URL, relativeDirectory: String, name: String) -> ScannedServiceCandidate? {
        let fileManager = FileManager.default
        func make(_ command: String, _ hint: String, port: UInt16) -> ScannedServiceCandidate {
            let service = ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: command,
                readiness: StoredReadiness(kind: .port, port: port, marker: nil),
                sourceHint: hint
            )
            return ScannedServiceCandidate(service: service, hasNestDependency: false)
        }

        if fileManager.fileExists(atPath: directory.appendingPathComponent("artisan").path) {
            return make("php artisan serve", "artisan (Laravel)", port: 8000)
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("composer.json").path),
           fileManager.fileExists(atPath: directory.appendingPathComponent("index.php").path) {
            return make("php -S localhost:8080", "composer.json", port: 8080)
        }
        return nil
    }

    private static func scanNodeService(
        packageJSONURL: URL,
        directory: URL,
        relativeDirectory: String,
        name: String
    ) -> ScannedServiceCandidate? {
        guard let data = try? Data(contentsOf: packageJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let scripts = json["scripts"] as? [String: Any] ?? [:]
        guard let script = npmScriptPriority.first(where: { scripts[$0] is String }) else { return nil }

        let fileManager = FileManager.default
        let command: String
        if fileManager.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) {
            command = "pnpm run \(script)"
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) {
            command = "yarn \(script)"
        } else {
            command = "npm run \(script)"
        }

        let dependencies = json["dependencies"] as? [String: Any] ?? [:]
        let hasNestDependency = dependencies["@nestjs/core"] != nil

        let service = ScannedService(
            name: name,
            relativeDirectory: relativeDirectory,
            command: command,
            readiness: readiness(forDirectory: directory, hasNestDependency: hasNestDependency),
            sourceHint: "package.json (\(script))"
        )
        return ScannedServiceCandidate(service: service, hasNestDependency: hasNestDependency)
    }

    // MARK: - Duplicate-port downgrade

    /// Se due servizi scansionati condividono la stessa porta rilevata, il primo (per ordine
    /// di sort, cioè `relativeDirectory` crescente) mantiene la readiness `.port`; i successivi
    /// vengono retrocessi al fallback non-porta (log marker Nest se applicabile, altrimenti
    /// processAlive) e ricevono un hint aggiuntivo per segnalare l'ambiguità.
    private static func downgradeDuplicatePorts(_ candidates: [ScannedServiceCandidate]) -> [ScannedService] {
        var seenPorts: Set<UInt16> = []
        var services: [ScannedService] = []
        services.reserveCapacity(candidates.count)

        for candidate in candidates {
            var service = candidate.service
            if let port = service.readiness.port {
                if seenPorts.contains(port) {
                    service.readiness = candidate.hasNestDependency
                        ? StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started")
                        : StoredReadiness(kind: .processAlive, port: nil, marker: nil)
                    service.sourceHint += " — porta \(port) duplicata"
                } else {
                    seenPorts.insert(port)
                }
            }
            services.append(service)
        }
        return services
    }

    // MARK: - Readiness (port sniffing + fallback)

    private static func readiness(forDirectory directory: URL, hasNestDependency: Bool) -> StoredReadiness {
        if let port = portFromEnvFile(in: directory) {
            return StoredReadiness(kind: .port, port: port, marker: nil)
        }
        if hasNestDependency {
            return StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started")
        }
        return StoredReadiness(kind: .processAlive, port: nil, marker: nil)
    }

    private static func portFromEnvFile(in directory: URL) -> UInt16? {
        let envURL = directory.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: envURL, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            values[key] = normalizeEnvValue(String(rawValue))
        }

        for key in envPortKeys {
            guard let rawValue = values[key], let port = UInt16(rawValue) else { continue }
            return port
        }
        return nil
    }

    /// Normalizza un valore grezzo di `.env`: se il valore inizia con una virgoletta (singola
    /// o doppia), individua la virgoletta di chiusura corrispondente e scarta tutto ciò che la
    /// segue (incluso un eventuale commento inline dopo la chiusura). Se invece il valore non è
    /// tra virgolette, tronca al primo commento inline (` #...`). Esempi: `"3000"` -> `3000`,
    /// `'8080'` -> `8080`, `3000 # web` -> `3000`, `"3000" # web` -> `3000`.
    private static func normalizeEnvValue(_ rawValue: String) -> String {
        if let quote = rawValue.first, quote == "\"" || quote == "'" {
            let afterQuote = rawValue.index(after: rawValue.startIndex)
            if let closingIndex = rawValue[afterQuote...].firstIndex(of: quote) {
                return String(rawValue[afterQuote..<closingIndex])
            }
        }
        if let commentRange = rawValue.range(of: " #") {
            return String(rawValue[rawValue.startIndex..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return rawValue
    }

    // MARK: - docker-compose infra detection

    private static func composeFiles(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter { url in
            let name = url.lastPathComponent
            return composeFileNames.contains(name)
                || (name.hasPrefix("docker-compose.") && name.hasSuffix(".yml"))
                || (name.hasPrefix("docker-compose.") && name.hasSuffix(".yaml"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func scanComposeInfra(in root: URL) -> StoredInfraCheck? {
        for composeFile in composeFiles(in: root) {
            guard let text = try? String(contentsOf: composeFile, encoding: .utf8) else { continue }
            let lowercasedText = text.lowercased()
            for signature in infraSignatures where lowercasedText.contains(signature.needle) {
                return signature.check
            }
        }
        return nil
    }

    // MARK: - docker-compose service detection

    /// File compose "di default" per la CLI `docker compose`: per questi il comando
    /// suggerito non ha bisogno di `-f`.
    private static let composeDefaultFileNames: Set<String> = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    ]

    /// Compose file da cui estrarre i servizi: quello di default se presente, altrimenti
    /// il primo in ordine alfabetico (deterministico). UNO solo: varianti dev/prod dello
    /// stesso progetto duplicherebbero i servizi.
    private static func preferredComposeFile(in root: URL) -> URL? {
        let files = composeFiles(in: root)
        return files.first { composeDefaultFileNames.contains($0.lastPathComponent) } ?? files.first
    }

    /// Servizi top-level del compose file preferito, ESCLUSI quelli che sembrano
    /// infrastruttura (nome o image che matcha `infraSignatures`): quelli restano
    /// appannaggio della spia infra, non diventano backend avviabili.
    /// Parsing line-based (indentazione convenzionale a 2 spazi): Foundation non ha un
    /// parser YAML e per questi layout non serve.
    private static func scanComposeServices(in root: URL) -> [ScannedServiceCandidate] {
        guard let composeFile = preferredComposeFile(in: root),
              let text = try? String(contentsOf: composeFile, encoding: .utf8) else { return [] }
        let fileName = composeFile.lastPathComponent
        let composePrefix = composeDefaultFileNames.contains(fileName)
            ? "docker compose"
            : "docker compose -f \(fileName)"

        var candidates: [ScannedServiceCandidate] = []
        var inServices = false
        var currentName: String?
        var currentIsInfra = false
        var currentHostPort: UInt16?
        var inPortsList = false

        func flushCurrentService() {
            defer { currentName = nil }
            guard let name = currentName, !currentIsInfra else { return }
            let readiness = currentHostPort.map { StoredReadiness(kind: .port, port: $0, marker: nil) }
                ?? StoredReadiness(kind: .processAlive, port: nil, marker: nil)
            let service = ScannedService(
                name: name,
                relativeDirectory: "",
                command: "\(composePrefix) up \(name)",
                readiness: readiness,
                sourceHint: "\(fileName) (\(name))"
            )
            candidates.append(ScannedServiceCandidate(service: service, hasNestDependency: false))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                flushCurrentService()
                inServices = trimmed == "services:"
                continue
            }
            guard inServices else { continue }

            if indent == 2, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                flushCurrentService()
                let name = String(trimmed.dropLast()).lowercased()
                currentName = name
                currentIsInfra = infraSignatures.contains { name.contains($0.needle) }
                currentHostPort = nil
                inPortsList = false
                continue
            }
            guard currentName != nil else { continue }

            if trimmed.hasPrefix("image:") {
                let image = trimmed.dropFirst("image:".count)
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if infraSignatures.contains(where: { image.contains($0.needle) }) {
                    currentIsInfra = true
                }
            } else if trimmed == "ports:" {
                inPortsList = true
            } else if inPortsList, trimmed.hasPrefix("-") {
                if currentHostPort == nil {
                    currentHostPort = hostPort(fromComposePortEntry: trimmed)
                }
            } else if !trimmed.hasPrefix("-") {
                // Altra chiave del servizio: l'eventuale lista `ports:` è finita.
                inPortsList = false
            }
        }
        flushCurrentService()
        return candidates
    }

    /// Porta HOST da una entry di `ports:` in sintassi breve: `- "8080:80"` → 8080,
    /// `- "127.0.0.1:9090:80"` → 9090 (penultimo segmento). Entry senza mapping esplicito
    /// (`- "8080"`, porta host assegnata dal demone) → `nil`.
    private static func hostPort(fromComposePortEntry entry: String) -> UInt16? {
        let value = entry.dropFirst()  // toglie "-"
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let parts = value.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return UInt16(parts[parts.count - 2])
    }

    // MARK: - Path helpers

    private static func relativePath(of directory: URL, root: URL) -> String {
        let rootPath = root.path
        let directoryPath = directory.path
        guard directoryPath != rootPath else { return "" }
        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard directoryPath.hasPrefix(rootWithSlash) else { return directoryPath }
        return String(directoryPath.dropFirst(rootWithSlash.count))
    }
}
