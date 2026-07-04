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

    @Test func detectsOpenPortViaIPv6Loopback() {
        // Servizio che ascolta solo su ::1 (nessun listener v4 sulla stessa porta):
        // isOpen deve comunque risultare true grazie al fallback IPv6.
        let listener = makeTCPListenerV6()
        defer { close(listener.fd) }
        #expect(PortCheck.isOpen(listener.port) == true)
    }
}
