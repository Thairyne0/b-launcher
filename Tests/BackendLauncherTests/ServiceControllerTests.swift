import Foundation
import Testing
@testable import BackendLauncher

/// Config fittizia: comandi brevi al posto di npm. cwd=/tmp esiste sempre.
private func fakeConfig(command: String) -> ServiceConfig {
    ServiceConfig(name: "fake", directory: "", port: 1, command: command)
}

@MainActor
@Suite struct ServiceControllerTests {
    @Test func crashSetsCrashedStatusWithExitCode() async {
        let c = ServiceController(config: fakeConfig(command: "exit 7"), cwd: "/tmp")
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashed)
    }

    @Test func userStopEndsInStoppedNotCrashed() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        let alive = await waitUntil { c.status == .starting }
        #expect(alive)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func restartSpawnsNewProcess() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.processID != nil }
        let firstPID = c.processID
        c.restart()
        let restarted = await waitUntil { c.processID != nil && c.processID != firstPID }
        #expect(restarted)
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func startWhilePortExternallyOpenIsRefused() async {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let config = ServiceConfig(name: "fake", directory: "", port: listener.port, command: "sleep 60")
        let c = ServiceController(config: config, cwd: "/tmp")
        c.portOpen = true
        #expect(c.status == .external)
        c.start()  // deve rifiutare: niente processo
        #expect(c.processID == nil)
    }

    @Test func runningWhenAliveAndPortMarkedOpen() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.portOpen = true
        #expect(c.status == .running)
        c.stop()
        _ = await waitUntil { c.processID == nil }
    }

    @Test func restartAfterCrashStartsFresh() async {
        let c = ServiceController(config: fakeConfig(command: "exit 7"), cwd: "/tmp")
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashed)
        c.restart()
        // restart() da .crashed NON è un no-op: start() è sincrono, quindi qui il
        // nuovo processo è già partito (nessun await tra restart e questo expect).
        #expect(c.status == .starting)
        // il nuovo "exit 7" esce di nuovo → di nuovo .crashed
        let crashedAgain = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashedAgain)
        // esattamente due banner di avvio nei log: il secondo start è avvenuto davvero
        #expect(c.logs.lines.filter { $0.text.contains("── avvio") }.count == 2)
    }

    @Test func spawnFailureBecomesCrashedMinusOne() async {
        let c = ServiceController(config: fakeConfig(command: "true"), cwd: "/nonexistent/xyz")
        c.start()
        #expect(c.status == .crashed(exitCode: -1))
    }

    @Test func natsOnlyServiceTurnsRunningOnLogMarker() async {
        // `start()` fa `exec <command>`: exec sostituisce l'intero processo shell con il
        // primo comando, quindi un `;` a livello superiore non lascerebbe mai eseguire il
        // secondo comando. `sh -c "..."` è il comando singolo che exec sostituisce, e AL SUO
        // INTERNO la sequenza `echo ...; sleep 60` gira normalmente.
        let config = ServiceConfig(name: "fake", directory: "", port: nil,
                                   command: #"sh -c "echo Nest microservice successfully started; sleep 60""#)
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        let running = await waitUntil { c.status == .running }
        #expect(running)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)  // marker resettato: niente .external fantasma
    }

    @Test func natsOnlyServiceStaysStartingWithoutMarker() async {
        let config = ServiceConfig(name: "fake", directory: "", port: nil, command: "sleep 60")
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.portOpen = true  // il poller non deve mai influire sui solo-NATS, ma anche se accadesse...
        #expect(c.status == .starting)  // ...il marker resta l'unico segnale
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func httpHealthReadinessDrivesStatus() async {
        let config = ServiceConfig(name: "fake", directory: "", command: "sleep 60",
                                   readiness: .httpHealth(port: 1, path: "/health"))
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.healthOK = true
        #expect(c.status == .running)
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func markRunningObservedRecordsStartupDurationOnce() async throws {
        let config = ServiceConfig(name: "fake", directory: "", command: "sleep 60",
                                   readiness: .processAlive)
        let c = ServiceController(config: config, cwd: "/tmp")
        #expect(c.lastStartupDuration == nil)
        c.start()
        _ = await waitUntil { c.status == .running }

        c.markRunningObserved()
        let first = try #require(c.lastStartupDuration)
        #expect(first >= 0 && first < 10)

        // Seconda osservazione dello STESSO avvio: non riscrive la misura.
        try await Task.sleep(for: .milliseconds(50))
        c.markRunningObserved()
        #expect(c.lastStartupDuration == first)

        c.stop()
        _ = await waitUntil { !c.processAlive }
    }

    @Test func appendCappedKeepsOnlyMostRecentValues() {
        var values: [Double] = []
        for i in 0..<40 { ServiceController.appendCapped(Double(i), to: &values, cap: 30) }
        #expect(values.count == 30)
        #expect(values.first == 10)
        #expect(values.last == 39)
    }

    @Test func envFileVariablesInjectedIntoProcessEnvironment() async throws {
        // File env alternativo: le variabili devono arrivare nell'ambiente del processo
        // (echo le rilegge), SENZA che il launcher scriva nulla nella working directory.
        let envURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-envfile-\(UUID().uuidString).env")
        try "FOO_BLAUNCHER=iniettata\n".write(to: envURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envURL) }

        var config = ServiceConfig(name: "fake", directory: "", port: nil,
                                   command: "echo VALORE=$FOO_BLAUNCHER && sleep 1")
        config.envFile = envURL.path
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        let seen = await waitUntil {
            c.logs.lines.contains { $0.text.contains("VALORE=iniettata") }
        }
        #expect(seen)
        c.stop()
        _ = await waitUntil { !c.processAlive }
    }

    @Test func crashInvokesOnCrashCallback() async {
        var captured: (String, Int32)?
        let c = ServiceController(config: fakeConfig(command: "exit 9"), cwd: "/tmp",
                                  onCrash: { captured = ($0, $1) })
        c.start()
        _ = await waitUntil { c.status == .crashed(exitCode: 9) }
        // Il callback riceve `displayName`, che ora è il nome puro (niente prefisso "skill").
        #expect(captured?.0 == "fake")
        #expect(captured?.1 == 9)
    }

    @Test func userStopDoesNotInvokeOnCrash() async {
        var invoked = false
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp",
                                  onCrash: { _, _ in invoked = true })
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.stop()
        _ = await waitUntil { c.status == .stopped }
        #expect(!invoked)
    }

    @Test func statsAppearWhileRunningAndClearOnStop() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        let gotStats = await waitUntil(timeout: 15) { c.stats != nil }
        #expect(gotStats)
        if let s = c.stats {
            #expect(s.rssMB > 0)
            #expect(s.cpuPercent >= 0)
        }
        c.stop()
        let cleared = await waitUntil { c.status == .stopped && c.stats == nil }
        #expect(cleared)
    }

    @Test func customLogMarkerTurnsRunning() async {
        // readiness .logMarker con stringa custom (non l'hardcoded "successfully started"):
        // il marker deve venire dalla config, non da una costante fissa nel controller.
        let config = ServiceConfig(name: "fake", directory: "", command:
                                   #"sh -c "echo PRONTO-XYZ; sleep 60""#,
                                   readiness: .logMarker("PRONTO-XYZ"))
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        let running = await waitUntil { c.status == .running }
        #expect(running)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func markerSplitAcrossChunksStillTurnsRunning() async {
        // Il marker viene scritto in due write() separati (flush + sleep intermedio), così
        // arriva a onChunk come due chunk distinti che spezzano la stringa del marker a metà.
        // Senza una coda "rolling tail" tra i chunk, un match che attraversa il confine
        // sfuggirebbe al controllo per-chunk.
        let config = ServiceConfig(name: "fake", directory: "", command:
                                   #"sh -c "printf 'SPLIT-MAR'; sleep 0.3; printf 'KER-XYZ\n'; sleep 60""#,
                                   readiness: .logMarker("SPLIT-MARKER-XYZ"))
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        let running = await waitUntil(timeout: 15) { c.status == .running }
        #expect(running)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func processAliveKindIsRunningImmediately() async {
        // readiness .processAlive: nessun segnale esterno necessario, "running" appena spawnato.
        let config = ServiceConfig(name: "fake", directory: "", command: "sleep 60",
                                   readiness: .processAlive)
        let c = ServiceController(config: config, cwd: "/tmp")
        c.start()
        let running = await waitUntil { c.status == .running }
        #expect(running)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func logFileURLPointsToTheActualLogFileOnDisk() async {
        // config.id "fake" (nessun projectName) -> nome file "fake.log", nella directory di
        // test dedicata (cwd != nil -> Self.testLogDirectory, stesso comportamento di
        // LogFileWriterTests ma passando dal controller invece che dal writer direttamente).
        // L'output del processo passa per `onChunk`, che scrive sia su `logs` che su
        // `fileWriter`: usiamo l'eco del comando reale, non `c.logs.ingest` diretto (quello
        // bypasserebbe il file writer).
        let c = ServiceController(config: fakeConfig(command: #"sh -c "echo riga-di-prova; sleep 60""#), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.processID != nil }
        // Attendi che la scrittura arrivi su disco (coda seriale asincrona in LogFileWriter).
        let wroteToDisk = await waitUntil {
            (try? String(contentsOf: c.logFileURL, encoding: .utf8))?.contains("riga-di-prova") == true
        }
        #expect(wroteToDisk)
        #expect(c.logFileURL.lastPathComponent == "fake.log")
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func restartDoesNotInvokeOnCrash() async {
        var invoked = false
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp",
                                  onCrash: { _, _ in invoked = true })
        c.start()
        _ = await waitUntil { c.processID != nil }
        c.restart()
        let restarted = await waitUntil { c.status == .starting || c.status == .running }
        #expect(restarted)
        #expect(!invoked)
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func exit0DoesNotNotify() async {
        var invoked = false
        let c = ServiceController(config: fakeConfig(command: "exit 0"), cwd: "/tmp",
                                  onCrash: { _, _ in invoked = true })
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 0) }
        #expect(crashed)
        #expect(!invoked)
    }

    // MARK: - wrappedShellCommand (A1 rc sourcing + A3 exec decision)

    @Test func wrappedShellCommandSourcesZshrcBeforeSimpleCommand() {
        let wrapped = ServiceController.wrappedShellCommand(for: "npm run start:dev")
        #expect(wrapped == "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1; exec npm run start:dev")
    }

    @Test func wrappedShellCommandSourcesZshrcBeforeCompoundCommandWithoutExec() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a && b")
        #expect(wrapped == "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1; a && b")
    }

    @Test func wrappedShellCommandUsesExecForSimpleCommand() {
        let wrapped = ServiceController.wrappedShellCommand(for: "npm run start:dev")
        #expect(wrapped.contains("exec npm run start:dev"))
    }

    @Test func wrappedShellCommandOmitsExecForAndAnd() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a && b")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForOrOr() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a || b")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForSemicolon() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a; b")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForPipe() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a | b")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForRedirect() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a > log")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForInputRedirect() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a < input")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForBackground() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a &")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForNewline() {
        let wrapped = ServiceController.wrappedShellCommand(for: "a\nb")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandOmitsExecForLeadingEnvAssignment() {
        let wrapped = ServiceController.wrappedShellCommand(for: "PORT=3000 npm start")
        #expect(!wrapped.contains("exec"))
    }

    @Test func wrappedShellCommandUsesExecForOrdinaryNpmCommand() {
        let wrapped = ServiceController.wrappedShellCommand(for: "npm run start:dev")
        #expect(wrapped.hasSuffix("exec npm run start:dev"))
    }
}
