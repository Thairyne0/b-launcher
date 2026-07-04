import Foundation

/// Identifica il processo in ascolto su una porta TCP locale, via `lsof`. Usato per dire
/// all'utente CHI tiene occupata la porta quando un servizio risulta "esterno" (blu):
/// così sa cosa fermare senza andare a caccia in Terminale.
enum PortOwner {
    /// `command (pid N)` del primo processo in LISTEN sulla porta, o `nil` se nessuno.
    /// Spawna `lsof`: sincrona e bloccante, chiamare fuori dal MainActor.
    static func describe(port: UInt16) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -nP: niente risoluzione DNS/porte (più veloce e stabile); -sTCP:LISTEN: solo
        // il processo in ascolto, non i client connessi.
        process.arguments = ["lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(lsofOutput: String(data: data, encoding: .utf8) ?? "")
    }

    /// Estrae `command (pid N)` dalla prima riga dati di `lsof` (le colonne sono
    /// COMMAND PID USER …). Header e output vuoto → `nil`.
    static func parse(lsofOutput: String) -> String? {
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2 else { continue }
            if columns[0] == "COMMAND" { continue }  // header
            guard Int(columns[1]) != nil else { continue }  // seconda colonna = PID
            return "\(columns[0]) (pid \(columns[1]))"
        }
        return nil
    }
}
