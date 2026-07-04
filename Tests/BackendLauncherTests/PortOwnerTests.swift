import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@Suite struct PortOwnerTests {
    /// Con un listener aperto nel processo di test, `describe` deve identificare il
    /// processo corrente (il suo pid compare nell'output di lsof).
    @Test func describeIdentifiesListeningProcess() {
        let listener = makeTCPListener()
        defer { close(listener.fd) }

        let owner = PortOwner.describe(port: listener.port)
        let description = try? #require(owner)
        #expect(description?.contains("\(getpid())") == true)
    }

    /// Porta quasi certamente libera: nessun processo in ascolto → nil.
    @Test func describeNilForFreePort() {
        // 1 è privilegiata e non in ascolto in un contesto di test normale.
        #expect(PortOwner.describe(port: 1) == nil)
    }

    // MARK: - parsing puro (indipendente da lsof)

    @Test func parseExtractsCommandAndPidFromLsofOutput() {
        let output = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    54321 retr0   23u  IPv4 0x1234567890abcdef      0t0  TCP *:4000 (LISTEN)
        """
        #expect(PortOwner.parse(lsofOutput: output) == "node (pid 54321)")
    }

    @Test func parseReturnsNilForHeaderOnlyOutput() {
        let output = "COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n"
        #expect(PortOwner.parse(lsofOutput: output) == nil)
    }

    @Test func parseReturnsNilForEmptyOutput() {
        #expect(PortOwner.parse(lsofOutput: "") == nil)
    }
}
