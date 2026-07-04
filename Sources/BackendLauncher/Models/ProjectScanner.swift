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

        var services: [ScannedService] = []
        for directory in candidateDirectories {
            guard let service = scanService(in: directory, root: standardizedRoot) else { continue }
            services.append(service)
        }
        services.sort { $0.relativeDirectory < $1.relativeDirectory }

        let suggestedInfraCheck = scanComposeInfra(in: standardizedRoot)

        return ScanResult(
            services: services,
            suggestedInfraCheck: suggestedInfraCheck,
            suggestedProjectName: standardizedRoot.lastPathComponent
        )
    }

    // MARK: - Per-directory detection

    private static func scanService(in directory: URL, root: URL) -> ScannedService? {
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
            return ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: "go run .",
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: "go.mod"
            )
        }

        let cargoTomlURL = directory.appendingPathComponent("Cargo.toml")
        if fileManager.fileExists(atPath: cargoTomlURL.path) {
            return ScannedService(
                name: name,
                relativeDirectory: relativeDirectory,
                command: "cargo run",
                readiness: readiness(forDirectory: directory, hasNestDependency: false),
                sourceHint: "Cargo.toml"
            )
        }

        return nil
    }

    private static func scanNodeService(
        packageJSONURL: URL,
        directory: URL,
        relativeDirectory: String,
        name: String
    ) -> ScannedService? {
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

        return ScannedService(
            name: name,
            relativeDirectory: relativeDirectory,
            command: command,
            readiness: readiness(forDirectory: directory, hasNestDependency: hasNestDependency),
            sourceHint: "package.json (\(script))"
        )
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
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        for key in envPortKeys {
            guard let rawValue = values[key], let port = UInt16(rawValue) else { continue }
            return port
        }
        return nil
    }

    // MARK: - docker-compose infra detection

    private static func scanComposeInfra(in root: URL) -> StoredInfraCheck? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        let composeFiles = entries.filter { url in
            let name = url.lastPathComponent
            return composeFileNames.contains(name)
                || (name.hasPrefix("docker-compose.") && name.hasSuffix(".yml"))
                || (name.hasPrefix("docker-compose.") && name.hasSuffix(".yaml"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for composeFile in composeFiles {
            guard let text = try? String(contentsOf: composeFile, encoding: .utf8) else { continue }
            let lowercasedText = text.lowercased()
            for signature in infraSignatures where lowercasedText.contains(signature.needle) {
                return signature.check
            }
        }
        return nil
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
