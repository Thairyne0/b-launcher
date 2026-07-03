import Foundation

/// Scrittura write-through dei log di un servizio su file, per post-mortem.
/// File: <directory>/<serviceName>.log — rotazione a maxBytes (rinomina in .old e ricomincia).
/// Thread-safety: tutte le scritture su una coda seriale dedicata; il chiamante non blocca.
final class LogFileWriter {
    let fileURL: URL
    private let queue = DispatchQueue(label: "logfilewriter", qos: .utility)
    private let maxBytes: UInt64
    private var handle: FileHandle?

    init(serviceName: String,
         directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
             .appendingPathComponent("Logs/BackendLauncher"),
         maxBytes: UInt64 = 5 * 1024 * 1024) {
        self.maxBytes = maxBytes
        self.fileURL = directory.appendingPathComponent("\(serviceName).log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Scrive il testo in coda, aprendo il file lazy alla prima scrittura e ruotando se
    /// la dimensione supera `maxBytes`. Best-effort: eventuali errori di I/O non propagano.
    func append(_ text: String) {
        queue.async { [self] in
            guard let data = text.data(using: .utf8) else { return }
            ensureOpenLocked()
            guard let handle else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                FileHandle.standardError.write("LogFileWriter: write failed for \(fileURL.lastPathComponent): \(error)\n".data(using: .utf8) ?? Data())
            }
            rotateIfNeededLocked()
        }
    }

    func appendBanner(_ line: String) {
        append("\n===== \(line) =====\n")
    }

    /// Chiude l'handle in modo sincrono rispetto al chiamante (attende lo svuotamento della coda).
    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    /// Solo per i test: attende che tutte le scritture accodate finora siano completate.
    func sync() {
        queue.sync {}
    }

    // MARK: - Privati (eseguiti sulla coda seriale)

    private func ensureOpenLocked() {
        guard handle == nil else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private func rotateIfNeededLocked() {
        guard let handle else { return }
        let size = (try? handle.offset()) ?? 0
        guard size > maxBytes else { return }
        try? handle.close()
        self.handle = nil

        let oldURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".old")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: fileURL, to: oldURL)
        // Il prossimo append riaprirà (creando) un file fresco.
    }
}
