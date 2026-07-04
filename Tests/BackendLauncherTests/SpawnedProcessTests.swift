import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@Suite struct SpawnedProcessTests {
    /// Colleziona output e exit code su una queue dedicata (il main loop non gira nei test).
    final class Recorder: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.recorder")
        var output = ""
        var exitCode: Int32?
        func chunk(_ s: String) { output += s }
        func exited(_ code: Int32) { exitCode = code }
    }

    @Test func capturesOutputAndExitCode() async throws {
        let rec = Recorder()
        _ = try SpawnedProcess(
            shellCommand: "echo hello-launcher; exit 3",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let done = await waitUntil {
            rec.queue.sync { rec.exitCode != nil && rec.output.contains("hello-launcher") }
        }
        #expect(done)
        rec.queue.sync {
            #expect(rec.output.contains("hello-launcher"))
            #expect(rec.exitCode == 3)
        }
    }

    @Test func terminateKillsWholeProcessGroup() async throws {
        let rec = Recorder()
        // zsh (leader) + sleep in background: il PID del figlio viene stampato
        let proc = try SpawnedProcess(
            shellCommand: "sleep 300 & echo CHILD:$!; wait",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let gotChild = await waitUntil { rec.queue.sync { rec.output.contains("CHILD:") } }
        #expect(gotChild)
        let childPID: pid_t = rec.queue.sync {
            let line = rec.output.split(separator: "\n").first { $0.hasPrefix("CHILD:") }!
            return pid_t(line.dropFirst("CHILD:".count))!
        }
        #expect(kill(childPID, 0) == 0)  // il nipote è vivo

        proc.terminate(gracePeriod: 1)

        let exited = await waitUntil { rec.queue.sync { rec.exitCode != nil } }
        #expect(exited)
        // anche il nipote deve essere morto (ucciso via process group)
        let grandchildDead = await waitUntil { kill(childPID, 0) != 0 }
        #expect(grandchildDead)
    }

    @Test func sigkillEscalationWhenSigtermIgnored() async throws {
        let rec = Recorder()
        // trap ignora SIGTERM: deve arrivare il SIGKILL dopo la grace period
        let proc = try SpawnedProcess(
            shellCommand: "trap '' TERM; echo READY; sleep 300",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let ready = await waitUntil { rec.queue.sync { rec.output.contains("READY") } }
        #expect(ready)
        proc.terminate(gracePeriod: 0.5)
        let exited = await waitUntil(timeout: 15) { rec.queue.sync { rec.exitCode != nil } }
        #expect(exited)
        rec.queue.sync {
            #expect(rec.exitCode == 128 + SIGKILL)  // 137
        }
    }

    @Test func spawnFailsForMissingCwd() {
        #expect(throws: (any Error).self) {
            _ = try SpawnedProcess(
                shellCommand: "true",
                cwd: "/nonexistent/path/xyz",
                callbackQueue: DispatchQueue(label: "t"),
                onChunk: { _ in },
                onExit: { _ in }
            )
        }
    }

    @Test func nonUTF8ChunkIsLossyDecodedNotDropped() async throws {
        // \xFF non è mai un byte UTF-8 valido da solo: con `String(data:encoding:.utf8)`
        // (strict) l'intero chunk andrebbe perso. Il fix usa `String(decoding:as:)` (lossy),
        // che sostituisce solo la sequenza non valida con U+FFFD ma mantiene il resto del
        // testo — verifichiamo che il testo circostante arrivi comunque a onChunk.
        let rec = Recorder()
        _ = try SpawnedProcess(
            shellCommand: #"printf 'before-\xFF-after\n'"#,
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let done = await waitUntil { rec.queue.sync { rec.exitCode != nil } }
        #expect(done)
        rec.queue.sync {
            #expect(rec.output.contains("before-"))
            #expect(rec.output.contains("-after"))
        }
    }

    @Test func childReceivesPythonUnbufferedEnvVar() async throws {
        // Il figlio deve vedere PYTHONUNBUFFERED=1 nell'ambiente, iniettato da SpawnedProcess
        // oltre all'environ del genitore, così l'output di Python non resta bloccato nel
        // block-buffering di libc quando stdout è una pipe.
        let rec = Recorder()
        _ = try SpawnedProcess(
            shellCommand: "echo $PYTHONUNBUFFERED",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let done = await waitUntil { rec.queue.sync { rec.exitCode != nil } }
        #expect(done)
        rec.queue.sync {
            #expect(rec.output.contains("1"))
        }
    }
}
