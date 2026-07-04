import Darwin
import Foundation
import Testing
@testable import BackendLauncher

/// Fixture per `EnvFileWriter`: ogni test lavora in una directory temporanea univoca,
/// mai su cartelle reali dell'utente. I test su `gitIgnoreStatus` usano `git` vero ma con
/// config global/system neutralizzata, così il `.gitignore` globale della macchina non
/// può cambiare l'esito (flakiness).
@Suite struct EnvFileWriterTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-envwriter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Ambiente git "sterile": nessuna config globale/di sistema dell'utente.
    private var sterileGitEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        return env
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        process.environment = sterileGitEnv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - envFileExists

    @Test func envFileExistsDetectsPresence() throws {
        let dir = try tempDir()
        #expect(!EnvFileWriter.envFileExists(in: dir))
        try "PORT=4000".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(EnvFileWriter.envFileExists(in: dir))
    }

    @Test func envFileMissingOnlyWhenDirectoryExistsWithoutEnv() throws {
        let dir = try tempDir()
        #expect(EnvFileWriter.envFileMissing(in: dir))
        try "PORT=4000".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(!EnvFileWriter.envFileMissing(in: dir))
        // Directory inesistente: nessun badge (c'è già l'indicatore "cartella mancante").
        #expect(!EnvFileWriter.envFileMissing(in: dir.appendingPathComponent("non-esiste")))
    }

    // MARK: - createEnvFile

    @Test func createWritesContentWithFinalNewlineAndOwnerOnlyPermissions() throws {
        let dir = try tempDir()
        try EnvFileWriter.createEnvFile(in: dir, content: "PORT=4000\nDB_PASS=secret")

        let url = dir.appendingPathComponent(".env")
        #expect(try String(contentsOf: url, encoding: .utf8) == "PORT=4000\nDB_PASS=secret\n")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(perms == 0o600)
    }

    @Test func createDoesNotDuplicateFinalNewline() throws {
        let dir = try tempDir()
        try EnvFileWriter.createEnvFile(in: dir, content: "PORT=4000\n")
        let written = try String(contentsOf: dir.appendingPathComponent(".env"), encoding: .utf8)
        #expect(written == "PORT=4000\n")
    }

    @Test func createFailsIfFileAlreadyExistsAndPreservesOriginal() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(".env")
        try "ORIGINALE=1".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: EnvFileWriter.EnvWriteError.alreadyExists) {
            try EnvFileWriter.createEnvFile(in: dir, content: "NUOVO=1")
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "ORIGINALE=1")
    }

    @Test func createFailsOnPreexistingSymlinkWithoutTouchingTarget() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent("altrove.txt")
        try "TARGET=1".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".env"),
                                                   withDestinationURL: target)

        #expect(throws: EnvFileWriter.EnvWriteError.alreadyExists) {
            try EnvFileWriter.createEnvFile(in: dir, content: "NUOVO=1")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "TARGET=1")
    }

    @Test func createFailsOnDanglingSymlink() throws {
        let dir = try tempDir()
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".env"),
                                                   withDestinationURL: dir.appendingPathComponent("inesistente"))

        #expect(throws: EnvFileWriter.EnvWriteError.alreadyExists) {
            try EnvFileWriter.createEnvFile(in: dir, content: "NUOVO=1")
        }
    }

    @Test func createFailsIfDirectoryMissing() throws {
        let dir = try tempDir().appendingPathComponent("non-esiste")
        #expect(throws: EnvFileWriter.EnvWriteError.directoryMissing) {
            try EnvFileWriter.createEnvFile(in: dir, content: "X=1")
        }
    }

    // MARK: - gitIgnoreStatus

    @Test func gitIgnoreStatusIgnoredWhenGitignoreCoversEnv() throws {
        let dir = try tempDir()
        try runGit(["init", "-q"], in: dir)
        try ".env\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(EnvFileWriter.gitIgnoreStatus(for: dir, environment: sterileGitEnv) == .ignored)
    }

    @Test func gitIgnoreStatusNotIgnoredInRepoWithoutGitignore() throws {
        let dir = try tempDir()
        try runGit(["init", "-q"], in: dir)
        #expect(EnvFileWriter.gitIgnoreStatus(for: dir, environment: sterileGitEnv) == .notIgnored)
    }

    @Test func gitIgnoreStatusNoRepoOutsideGit() throws {
        let dir = try tempDir()
        #expect(EnvFileWriter.gitIgnoreStatus(for: dir, environment: sterileGitEnv) == .noRepo)
    }

    // MARK: - envKeyCount

    @Test func envKeyCountCountsOnlyValidAssignments() {
        let content = """
        # commento
        PORT=4000

        DB_PASS=s3cr3t=con=uguali
        export NODE_ENV=development
        =senza-chiave
        123CHIAVE=inizia-con-numero
        riga senza uguale
        _PRIVATA=ok
        """
        #expect(EnvFileWriter.envKeyCount(content) == 4)
    }

    @Test func envKeyCountHandlesCRLF() {
        #expect(EnvFileWriter.envKeyCount("A=1\r\nB=2\r\n") == 2)
    }

    @Test func envKeyCountEmptyContent() {
        #expect(EnvFileWriter.envKeyCount("") == 0)
        #expect(EnvFileWriter.envKeyCount("# solo commenti\n\n") == 0)
    }
}
