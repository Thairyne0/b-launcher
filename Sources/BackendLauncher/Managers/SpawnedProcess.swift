import Darwin
import Foundation

/// Processo figlio in un process group dedicato, stdout+stderr su pipe.
///
/// - Lancio: `/bin/zsh -l -c <command>` (login shell: risolve npm da Homebrew
///   via zprofile; non serve una shell interattiva).
/// - Stop: `killpg(SIGTERM)` → grace period → `killpg(SIGKILL)`.
///   Uccide npm + node + watcher NestJS in blocco, senza orfani.
/// - I callback arrivano su `callbackQueue` (default: main).
final class SpawnedProcess {
    enum SpawnError: Error, LocalizedError {
        case pipeFailed(Int32)
        case spawnFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .pipeFailed(let e): return "pipe() fallita: errno \(e)"
            case .spawnFailed(let e): return "posix_spawn fallita: errno \(e) (\(String(cString: strerror(e))))"
            }
        }
    }

    /// Mantiene vive le istanze "in volo" indipendentemente da chi le ha create: il chiamante
    /// può scartare il valore ritornato da `init` (fire-and-forget) e i callback devono
    /// comunque arrivare finché il processo non è stato reaped. Si rimuove da qui l'istanza
    /// non appena l'exit è stato osservato — a quel punto non c'è più nulla da monitorare.
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: SpawnedProcess] = [:]

    let pid: pid_t
    private let readHandle: FileHandle
    private let exitSource: DispatchSourceProcess
    private let callbackQueue: DispatchQueue
    private let stateLock = NSLock()
    private var _alive = true

    /// Estremo di scrittura della pipe stdin del figlio (terminale interattivo). Protetto
    /// da `stdinLock`; messo a -1 dopo la chiusura per non scrivere su un fd riciclato.
    private let stdinLock = NSLock()
    private var stdinWriteFD: Int32 = -1

    /// Riflette solo lo stato del processo leader (reaped via waitpid), NON del process group.
    /// Non usarlo come gate per l'escalation SIGKILL: il leader può terminare da SIGTERM
    /// mentre un discendente nello stesso group è ancora vivo (vedi `terminate`).
    var isAlive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _alive
    }

    init(shellCommand: String, cwd: String,
         extraEnvironment: [String: String] = [:],
         callbackQueue: DispatchQueue = .main,
         onChunk: @escaping (String) -> Void,
         onExit: @escaping (Int32) -> Void) throws {
        self.callbackQueue = callbackQueue

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError.pipeFailed(errno) }
        let readFD = fds[0], writeFD = fds[1]

        // Pipe stdin (terminale interattivo): il figlio legge da `stdinReadFD` su fd 0,
        // il padre scrive su `stdinWriteFD`. Se fallisce, l'output funziona comunque:
        // ripieghiamo su /dev/null per lo stdin del figlio.
        var stdinFDs: [Int32] = [0, 0]
        let hasStdinPipe = pipe(&stdinFDs) == 0
        let stdinReadFD = hasStdinPipe ? stdinFDs[0] : -1
        let stdinWriteFDLocal = hasStdinPipe ? stdinFDs[1] : -1

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 2)
        if hasStdinPipe {
            posix_spawn_file_actions_adddup2(&fileActions, stdinReadFD, 0)
            posix_spawn_file_actions_addclose(&fileActions, stdinReadFD)
            posix_spawn_file_actions_addclose(&fileActions, stdinWriteFDLocal)
        }
        posix_spawn_file_actions_addclose(&fileActions, readFD)
        posix_spawn_file_actions_addclose(&fileActions, writeFD)
        let chdirRC = posix_spawn_file_actions_addchdir(&fileActions, cwd)
        guard chdirRC == 0 else {
            close(readFD)
            close(writeFD)
            if hasStdinPipe { close(stdinReadFD); close(stdinWriteFDLocal) }
            throw SpawnError.spawnFailed(chdirRC)
        }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)  // il figlio guida il proprio group (pgid == pid)

        let argv = ["/bin/zsh", "-l", "-c", shellCommand]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { cArgv.forEach { free($0) } }

        var cEnv: [UnsafeMutablePointer<CChar>?] = Self.childEnvironment(extra: extraEnvironment).map { strdup($0) }
        cEnv.append(nil)
        defer { cEnv.forEach { free($0) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, "/bin/zsh", &fileActions, &attrs, &cArgv, &cEnv)
        close(writeFD)  // lato scrittura resta solo nel figlio
        if hasStdinPipe { close(stdinReadFD) }  // lato lettura resta solo nel figlio
        guard rc == 0 else {
            close(readFD)
            if hasStdinPipe { close(stdinWriteFDLocal) }
            throw SpawnError.spawnFailed(rc)
        }
        pid = childPID
        stdinWriteFD = stdinWriteFDLocal

        readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {  // EOF
                handle.readabilityHandler = nil
                return
            }
            // Decodifica "lossy": un chunk di pipe può spezzare una sequenza multibyte UTF-8
            // esattamente al confine, o il processo figlio può scrivere byte non-UTF-8 (es.
            // output binario accidentale). `String(data:encoding:.utf8)` (strict) scarterebbe
            // l'INTERO chunk in questi casi — meglio sostituire solo la parte non valida con
            // U+FFFD e mostrare comunque il resto del testo nei log.
            let text = String(decoding: data, as: UTF8.self)
            callbackQueue.async { onChunk(text) }
        }

        exitSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit,
                                                      queue: callbackQueue)
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)  // reap: niente zombie
            self?.markDead()
            onExit(Self.decodeExitStatus(status))
            self?.exitSource.cancel()
            // A questo punto il processo è reaped: nessun altro evento arriverà.
            // Rilascia il self-retain — se il chiamante non tiene un suo riferimento,
            // l'istanza può deallocare da qui in poi.
            if let self { Self.unregister(self) }
        }
        exitSource.resume()

        // Self-retain: l'istanza resta viva anche se il chiamante scarta il valore di ritorno
        // (fire-and-forget), finché l'exit handler sopra non la deregistra.
        Self.register(self)
    }

    private static func register(_ instance: SpawnedProcess) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[ObjectIdentifier(instance)] = instance
    }

    private static func unregister(_ instance: SpawnedProcess) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[ObjectIdentifier(instance)] = nil
    }

    /// SIGTERM al process group; SIGKILL se dopo `gracePeriod` il gruppo ha ancora membri vivi.
    ///
    /// La escalation NON si basa su `isAlive` (che riflette solo il leader): il leader può
    /// morire da SIGTERM quasi subito mentre un discendente nello stesso group (es. un
    /// processo in background lanciato con `&`) impiega più tempo a reagire allo stesso
    /// segnale. Si sonda il process group direttamente con `killpg(pid, 0)`: nessun segnale
    /// viene consegnato, ma l'esito rivela se qualche membro del gruppo risponde ancora.
    /// Scrive `text` sullo stdin del figlio (terminale interattivo). Best-effort:
    /// se il figlio ha già chiuso lo stdin (EPIPE) o la pipe non esiste, no-op silenzioso.
    /// Il chiamante include l'eventuale `\n` per "inviare una riga".
    func sendInput(_ text: String) {
        stdinLock.lock(); defer { stdinLock.unlock() }
        guard stdinWriteFD >= 0 else { return }
        let bytes = Array(text.utf8)
        var offset = 0
        bytes.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let n = write(stdinWriteFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return  // EPIPE/altro: il figlio non legge più, lascia perdere
                }
                offset += n
            }
        }
    }

    /// Chiude lo stdin del figlio (EOF): usato in `terminate` e a fine vita. Idempotente.
    private func closeStdin() {
        stdinLock.lock(); defer { stdinLock.unlock() }
        if stdinWriteFD >= 0 { close(stdinWriteFD); stdinWriteFD = -1 }
    }

    func terminate(gracePeriod: TimeInterval = 5) {
        closeStdin()  // EOF su stdin: i programmi che lo leggono escono da soli
        killpg(pid, SIGTERM)
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            errno = 0
            let probeRC = killpg(pid, 0)
            // rc == 0 (o rc == -1 con EPERM) → qualcuno nel gruppo esiste ancora.
            // rc == -1 con ESRCH → il process group non ha più membri: nulla da uccidere.
            let groupStillHasMembers = probeRC == 0 || (probeRC == -1 && errno == EPERM)
            guard groupStillHasMembers else { return }
            killpg(pid, SIGKILL)
        }
    }

    private func markDead() {
        stateLock.lock(); _alive = false; stateLock.unlock()
        closeStdin()  // il figlio è morto: rilascia il write-end della pipe stdin
    }

    /// wait(2) status → exit code convenzionale (segnale N → 128+N).
    static func decodeExitStatus(_ status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }  // uscita normale
        return 128 + low                              // terminato da segnale
    }

    /// Snapshot dell'`environ` del genitore ("KEY=VALUE" per riga) più le variabili che
    /// forziamo per il figlio, quando non già impostate esplicitamente dall'utente:
    /// - `PYTHONUNBUFFERED=1`: quando stdout è una pipe (sempre il nostro caso) libc passa a
    ///   block-buffering invece di line-buffering, quindi l'output di un processo Python resta
    ///   invisibile nei log finché il buffer non si riempie. Questa var forza `sys.stdout`/
    ///   `sys.stderr` non bufferizzati fin dall'avvio dell'interprete.
    /// `extra`: variabili del file env alternativo del servizio — VINCONO sulle chiavi
    /// omonime dell'ambiente del launcher (è la scelta esplicita dell'utente).
    static func childEnvironment(extra: [String: String] = [:]) -> [String] {
        var seenKeys = Set<String>()
        var result: [String] = []
        var i = 0
        while let entry = environ[i] {
            let pair = String(cString: entry)
            i += 1
            if let eq = pair.firstIndex(of: "=") {
                let key = String(pair[pair.startIndex..<eq])
                seenKeys.insert(key)
                if extra[key] != nil { continue }  // sovrascritta: appesa sotto
            }
            result.append(pair)
        }
        for (key, value) in extra {
            result.append("\(key)=\(value)")
            seenKeys.insert(key)
        }
        if !seenKeys.contains("PYTHONUNBUFFERED") {
            result.append("PYTHONUNBUFFERED=1")
        }
        // stdout è una pipe (mai una TTY): chalk/Nest/pino spengono i colori da soli.
        // Il terminale del launcher ora RENDERIZZA gli escape SGR (ANSIParser), quindi
        // chiediamo ai logger di emetterli comunque — salvo scelta esplicita dell'utente.
        if !seenKeys.contains("FORCE_COLOR") {
            result.append("FORCE_COLOR=1")
        }
        if !seenKeys.contains("CLICOLOR_FORCE") {
            result.append("CLICOLOR_FORCE=1")
        }
        return result
    }
}
