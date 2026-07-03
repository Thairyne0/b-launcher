import Darwin
import Testing
@testable import BackendLauncher

@Suite struct PortCheckTests {
    @Test func detectsOpenPort() {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        #expect(PortCheck.isOpen(listener.port) == true)
    }

    @Test func detectsClosedPort() async {
        // apri e chiudi subito: la porta deve risultare libera
        // (retry: il teardown del socket nel kernel è asincrono sotto carico)
        let listener = makeTCPListener()
        let port = listener.port
        close(listener.fd)
        let closed = await waitUntil(timeout: 2) { PortCheck.isOpen(port) == false }
        #expect(closed)
    }
}
