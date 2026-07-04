import Darwin
import Foundation

/// Probe TCP non bloccante su loopback (127.0.0.1 e ::1). Nessuna dipendenza, testabile.
enum PortCheck {
    static func isOpen(_ port: UInt16, timeoutMs: Int32 = 500) -> Bool {
        if isOpenV4(port, timeoutMs: timeoutMs) { return true }
        return isOpenV6(port, timeoutMs: timeoutMs)
    }

    private static func isOpenV4(_ port: UInt16, timeoutMs: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return finishConnect(fd: fd, connectResult: connectResult, timeoutMs: timeoutMs)
    }

    private static func isOpenV6(_ port: UInt16, timeoutMs: Int32) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd)

        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = port.bigEndian
        addr6.sin6_addr = in6addr_loopback

        let connectResult = withUnsafePointer(to: &addr6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return finishConnect(fd: fd, connectResult: connectResult, timeoutMs: timeoutMs)
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Fase condivisa non bloccante: interpreta l'esito di `connect` (già in O_NONBLOCK),
    /// e se in corso (EINPROGRESS) attende via poll() fino a timeoutMs verificando SO_ERROR.
    private static func finishConnect(fd: Int32, connectResult: Int32, timeoutMs: Int32) -> Bool {
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var pollResult: Int32
        repeat {
            pollResult = poll(&pfd, 1, timeoutMs)
        } while pollResult == -1 && errno == EINTR
        guard pollResult == 1 else { return false }

        var soError: Int32 = -1
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }
}
