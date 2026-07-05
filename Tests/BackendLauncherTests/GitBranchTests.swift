import Foundation
import Testing
@testable import BackendLauncher

@Suite struct GitBranchTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-gitbranch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var sterileGitEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        return env
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path,
                             "-c", "user.name=test", "-c", "user.email=test@test"] + arguments
        process.environment = sterileGitEnv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func currentReturnsBranchName() throws {
        let dir = try tempDir()
        runGit(["init", "-q", "-b", "feature/nuova"], in: dir)
        try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."], in: dir)
        runGit(["commit", "-q", "-m", "primo"], in: dir)

        #expect(GitBranch.current(in: dir, environment: sterileGitEnv) == "feature/nuova")
    }

    @Test func currentNilOutsideRepo() throws {
        let dir = try tempDir()
        #expect(GitBranch.current(in: dir, environment: sterileGitEnv) == nil)
    }

    @Test func currentNilForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-gitbranch-non-esiste-\(UUID().uuidString)")
        #expect(GitBranch.current(in: missing, environment: sterileGitEnv) == nil)
    }

    /// Il refresh di AppModel popola branch + mismatch: due servizi su "main", uno su
    /// "feature/x" → solo quest'ultimo è in mismatch.
    @MainActor
    @Test func appModelRefreshMarksMismatchAgainstMajority() async throws {
        func makeRepo(branch: String) throws -> URL {
            let dir = try tempDir()
            runGit(["init", "-q", "-b", branch], in: dir)
            try "x".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            runGit(["add", "."], in: dir)
            runGit(["commit", "-q", "-m", "primo"], in: dir)
            return dir
        }
        let mainA = try makeRepo(branch: "main")
        let mainB = try makeRepo(branch: "main")
        let feature = try makeRepo(branch: "feature/x")

        let configs = [
            ServiceConfig(name: "a", directory: "", port: 1, absoluteDirectory: mainA, projectName: "P"),
            ServiceConfig(name: "b", directory: "", port: 2, absoluteDirectory: mainB, projectName: "P"),
            ServiceConfig(name: "c", directory: "", port: 3, absoluteDirectory: feature, projectName: "P"),
        ]
        let model = AppModel(configs: configs, pollingEnabled: false, crashNotificationsEnabled: false)

        await model.refreshGitBranches()

        #expect(model.services[0].gitBranch == "main")
        #expect(model.services[2].gitBranch == "feature/x")
        #expect(model.services[0].gitBranchMismatch == false)
        #expect(model.services[2].gitBranchMismatch == true)
    }

    /// Branch "di maggioranza" di un progetto: usato per evidenziare il servizio fuori
    /// allineamento. Nil se non c'è maggioranza assoluta o meno di due branch noti.
    @Test func majorityBranchPicksMostCommon() {
        #expect(GitBranch.majority(of: ["main", "main", "feature/x"]) == "main")
        #expect(GitBranch.majority(of: ["main"]) == "main")
        #expect(GitBranch.majority(of: []) == nil)
        // Pareggio: nessuna maggioranza → nil (nessun warning arbitrario).
        #expect(GitBranch.majority(of: ["main", "feature/x"]) == nil)
    }
}
