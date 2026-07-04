import Foundation

/// Check aggiornamenti in-app: confronta il clone git da cui l'app è stata buildata
/// (path in `BLRepoPath` dell'Info.plist, iniettato da make-app.sh) con il suo upstream.
/// L'update vero e proprio resta `make update` (lanciato in Terminale): l'app non si
/// auto-sostituisce, mostra solo quanto è indietro.
enum UpdateChecker {
    enum Status: Equatable {
        case upToDate
        case behind(commits: Int)
        case unavailable(reason: String)
    }

    /// Path del clone da cui questa build proviene. `nil` da `swift run`/test (nessuna
    /// chiave nel bundle) o se la directory nel frattempo è sparita (clone spostato).
    static var repoPath: String? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "BLRepoPath") as? String else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    /// `git fetch` + `rev-list --count HEAD..@{upstream}` nel clone. Sincrona e bloccante
    /// (rete): chiamare fuori dal MainActor. `environment` iniettabile solo per i test.
    static func check(repoPath: String, environment: [String: String]? = nil) -> Status {
        guard FileManager.default.fileExists(atPath: repoPath) else {
            return .unavailable(reason: "La cartella del clone non esiste più.")
        }
        let fetch = runGit(["fetch", "-q"], in: repoPath, environment: environment)
        guard fetch.exitCode == 0 else {
            return .unavailable(reason: fetch.exitCode == 128
                ? "Non è un repository git (o il remoto non è raggiungibile)."
                : "git fetch fallito (offline?).")
        }
        let revList = runGit(["rev-list", "--count", "HEAD..@{upstream}"],
                             in: repoPath, environment: environment)
        guard revList.exitCode == 0,
              let count = Int(revList.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unavailable(reason: "Nessun upstream configurato per il branch corrente.")
        }
        return count == 0 ? .upToDate : .behind(commits: count)
    }

    /// Apre Terminale ed esegue `make update` nel clone: pull + rebuild + reinstall.
    /// Il Makefile chiude l'app come primo passo, quindi da qui in poi è il Terminale
    /// (visibile all'utente) a raccontare cosa succede.
    static func runUpdateInTerminal(repoPath: String) {
        let escapedPath = repoPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedPath)\\" && make update"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func runGit(_ arguments: [String], in directory: String,
                               environment: [String: String]?) -> (exitCode: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
