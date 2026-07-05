import Foundation

/// Branch git corrente della working directory di un servizio (badge sulla card).
/// Spawna `git`: mai a render time — il poller di AppModel aggiorna una cache
/// per servizio ogni ~10 tick, come il controllo di sync dei template.
enum GitBranch {
    /// `git rev-parse --abbrev-ref HEAD`. `nil` fuori da un repo, directory mancante,
    /// o HEAD detached senza nome ("HEAD" viene scartato: non è un branch).
    static func current(in directory: URL, environment: [String: String]? = nil) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--abbrev-ref", "HEAD"]
        if let environment { process.environment = environment }
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
        guard process.terminationStatus == 0 else { return nil }
        let branch = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Branch a maggioranza ASSOLUTA (> metà) tra quelli passati: usato per evidenziare
    /// il servizio fuori allineamento rispetto al resto del progetto. Pareggio o lista
    /// vuota → `nil` (nessun warning arbitrario).
    static func majority(of branches: [String]) -> String? {
        guard !branches.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for branch in branches { counts[branch, default: 0] += 1 }
        guard let (branch, count) = counts.max(by: { $0.value < $1.value }),
              count * 2 > branches.count else { return nil }
        return branch
    }
}
