import Darwin
import Testing
@testable import BackendLauncher

@Suite struct PortCheckTests {
    @Test func detectsOpenPort() {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        #expect(PortCheck.isOpen(listener.port) == true)
    }

    @Test func detectsClosedPort() {
        // apri e chiudi subito: la porta risulta libera
        let listener = makeTCPListener()
        let port = listener.port
        close(listener.fd)
        #expect(PortCheck.isOpen(port) == false)
    }
}
