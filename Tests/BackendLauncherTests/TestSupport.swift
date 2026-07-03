import Darwin
import Foundation

/// Listener TCP su 127.0.0.1, porta assegnata dal kernel. Chiudere con `close(fd)`.
func makeTCPListener() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bindResult == 0, "bind() failed")
    precondition(listen(fd, 8) == 0, "listen() failed")

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = getsockname(fd, $0, &len)
        }
    }
    return (fd, UInt16(bigEndian: bound.sin_port))
}

/// Polling asincrono di una condizione con timeout. Ritorna true se soddisfatta in tempo.
func waitUntil(timeout: TimeInterval = 10, interval: TimeInterval = 0.05,
               _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return condition()
}
