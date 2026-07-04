import Foundation
import Testing
@testable import BackendLauncher

/// Fixture: coppia origin+clone in directory temporanee, git vero con config sterile
/// (nessuna config globale/di sistema dell'utente può cambiare gli esiti). Il "remoto"
/// è un path locale: `fetch` funziona senza rete.
@Suite struct UpdateCheckerTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-update-tests-\(UUID().uuidString)")
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
        // user.name/email inline: commit deve funzionare senza config globale.
        process.arguments = ["git", "-C", directory.path,
                             "-c", "user.name=test", "-c", "user.email=test@test"] + arguments
        process.environment = sterileGitEnv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// origin con un commit + clone agganciato. Ritorna (origin, clone).
    private func makeOriginAndClone() throws -> (origin: URL, clone: URL) {
        let root = try tempDir()
        let origin = root.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        runGit(["init", "-q"], in: origin)
        try "uno\n".write(to: origin.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."], in: origin)
        runGit(["commit", "-q", "-m", "primo"], in: origin)

        let clone = root.appendingPathComponent("clone")
        runGit(["clone", "-q", origin.path, clone.path], in: root)
        return (origin, clone)
    }

    @Test func upToDateWhenCloneMatchesOrigin() throws {
        let (_, clone) = try makeOriginAndClone()
        #expect(UpdateChecker.check(repoPath: clone.path, environment: sterileGitEnv) == .upToDate)
    }

    @Test func behindCountsNewOriginCommits() throws {
        let (origin, clone) = try makeOriginAndClone()
        try "due\n".write(to: origin.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."], in: origin)
        runGit(["commit", "-q", "-m", "secondo"], in: origin)
        try "tre\n".write(to: origin.appendingPathComponent("file3.txt"), atomically: true, encoding: .utf8)
        runGit(["add", "."], in: origin)
        runGit(["commit", "-q", "-m", "terzo"], in: origin)

        #expect(UpdateChecker.check(repoPath: clone.path, environment: sterileGitEnv)
                == .behind(commits: 2))
    }

    @Test func unavailableOutsideAGitRepo() throws {
        let dir = try tempDir()
        if case .unavailable = UpdateChecker.check(repoPath: dir.path, environment: sterileGitEnv) {
            // ok
        } else {
            Issue.record("atteso .unavailable fuori da un repo git")
        }
    }

    @Test func unavailableWhenDirectoryMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-update-non-esiste-\(UUID().uuidString)")
        if case .unavailable = UpdateChecker.check(repoPath: missing.path, environment: sterileGitEnv) {
            // ok
        } else {
            Issue.record("atteso .unavailable con directory inesistente")
        }
    }

    @Test func repoPathNilInTestBundle() {
        // Il bundle dei test non ha BLRepoPath (chiave iniettata solo da make-app.sh).
        #expect(UpdateChecker.repoPath == nil)
    }
}
