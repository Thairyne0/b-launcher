import Darwin
import Foundation

/// Creazione sicura del file `.env` di un backend (feature "badge .env mancante").
/// Vincoli di sicurezza (spec 2026-07-04): mai sovrascrivere, permessi 0600, verifica
/// `.gitignore` prima di scrivere, il contenuto non transita mai da log o persistenza.
enum EnvFileWriter {
    enum GitIgnoreStatus: Equatable {
        case ignored
        case notIgnored
        case noRepo
        case unknown
    }

    enum EnvWriteError: Error, Equatable {
        case alreadyExists
        case directoryMissing
        case writeFailed(errno: Int32)
    }

    static func envFileExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".env").path)
    }

    /// Condizione del badge UI ".env mancante": la directory esiste ma non contiene `.env`.
    /// Directory inesistente → `false`: quel caso ha già il suo indicatore dedicato
    /// ("cartella mancante") e un badge .env sarebbe rumore.
    static func envFileMissing(in directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !envFileExists(in: directory)
    }

    /// Nomi convenzionali del template d'esempio dell'env, in ordine di priorità.
    private static let exampleFileNames = [".env.example", ".env.sample", ".env.template", ".env.dist"]

    /// Contenuto del primo template d'esempio presente nella cartella (`.env.example` &co.),
    /// usato per precompilare l'editor dello sheet. Sola lettura del backend. Cap a 1 MB:
    /// un "esempio" più grande non è un esempio, è un file sbagliato.
    static func exampleContent(in directory: URL) -> (fileName: String, content: String)? {
        for fileName in exampleFileNames {
            let url = directory.appendingPathComponent(fileName)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes?[.size] as? NSNumber)?.intValue, size <= 1_000_000 else { continue }
            guard let content = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { continue }
            return (fileName, content)
        }
        return nil
    }

    /// Esito di `git -C <dir> check-ignore -q .env`. Rispetta anche la config globale
    /// dell'utente (un `core.excludesfile` che copre `.env` protegge dal commit tanto quanto
    /// il `.gitignore` di repo); `environment` è iniettabile solo per rendere i test immuni
    /// da quella stessa config.
    static func gitIgnoreStatus(for directory: URL,
                                environment: [String: String]? = nil) -> GitIgnoreStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "check-ignore", "-q", ".env"]
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unknown
        }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return .ignored
        case 1: return .notIgnored
        case 128: return .noRepo
        default: return .unknown  // git assente (127 da env) o errore imprevisto
        }
    }

    /// Crea `<directory>/.env` con `content` (+ newline finale se manca) e permessi 0600.
    /// `O_EXCL` fa fallire la syscall se il path esiste già in QUALSIASI forma — file,
    /// symlink (anche dangling) — senza finestra check-then-write: l'unico modo corretto
    /// di garantire "mai sovrascrivere".
    static func createEnvFile(in directory: URL, content: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EnvWriteError.directoryMissing
        }

        let path = directory.appendingPathComponent(".env").path
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else {
            throw errno == EEXIST ? EnvWriteError.alreadyExists
                                  : EnvWriteError.writeFailed(errno: errno)
        }
        defer { close(fd) }

        var bytes = Array(content.utf8)
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }

        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                // Scrittura parziale: non lasciare un .env troncato che sembrerebbe valido.
                let savedErrno = errno
                unlink(path)
                throw EnvWriteError.writeFailed(errno: savedErrno)
            }
            offset += written
        }
    }

    /// Conta le righe che sembrano assegnazioni dotenv valide (`KEY=...`, `export KEY=...`),
    /// ignorando vuote e commenti. Solo feedback UI ("N variabili rilevate"): il contenuto
    /// viene comunque scritto com'è, mai interpretato.
    static func envKeyCount(_ content: String) -> Int {
        var count = 0
        // `whereSeparator: \.isNewline` e non `separator: "\n"`: in Swift "\r\n" è un
        // singolo Character (grapheme cluster) diverso da "\n", quindi un file CRLF non
        // verrebbe mai splittato riga per riga.
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let equalsIndex = line.firstIndex(of: "="),
                  equalsIndex != line.startIndex else { continue }
            let key = line[line.startIndex..<equalsIndex]
            let first = key.first!
            guard (first.isASCII && first.isLetter) || first == "_" else { continue }
            if key.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }) {
                count += 1
            }
        }
        return count
    }
}
