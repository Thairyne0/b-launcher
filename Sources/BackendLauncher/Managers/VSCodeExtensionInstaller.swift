import Foundation

/// Installa l'estensione VSCode di Backend Launcher dal `.vsix` presente nel clone
/// (sottocartella `vscode-extension/`), via `code --install-extension`. Pre-marketplace:
/// l'utente installa l'estensione con un click dall'app nativa.
enum VSCodeExtensionInstaller {
    enum Result: Equatable {
        case installed(name: String)
        case noRepo
        case noVsix
        case failed(String)
    }

    /// Directory dell'estensione dentro il clone (da `BLRepoPath`, come UpdateChecker).
    static var extensionDirectory: URL? {
        UpdateChecker.repoPath.map {
            URL(fileURLWithPath: $0).appendingPathComponent("vscode-extension")
        }
    }

    /// `.vsix` più recente in una directory (per versione/mtime): scelta pura e testabile.
    /// Preferisce il maggiore per nome (le versioni crescono), a parità niente tie-break.
    static func newestVsix(in files: [String]) -> String? {
        files.filter { $0.hasSuffix(".vsix") }.max()
    }

    /// Trova e installa il `.vsix`. Sincrona e bloccante (spawna `code`): fuori dal MainActor.
    static func install() -> Result {
        guard let dir = extensionDirectory,
              FileManager.default.fileExists(atPath: dir.path) else {
            return .noRepo
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let vsix = newestVsix(in: names) else { return .noVsix }
        let vsixPath = dir.appendingPathComponent(vsix).path

        // `code` va risolto dalla login shell (una GUI app non eredita il PATH del terminale).
        let escaped = vsixPath.replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "code --install-extension \"\(escaped)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .failed("Impossibile lanciare code: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return .installed(name: vsix)
        }
        if output.lowercased().contains("command not found") || output.contains("zsh:") {
            return .failed("Comando 'code' non trovato. In VSCode: Cmd+Shift+P → \"Shell Command: Install 'code' command in PATH\".")
        }
        return .failed(output.isEmpty ? "Installazione non riuscita." : output)
    }
}
