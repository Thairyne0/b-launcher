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

/// Listener TCP su ::1 (IPv6 loopback), porta assegnata dal kernel. Chiudere con `close(fd)`.
func makeTCPListenerV6() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in6()
    addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = 0
    addr.sin6_addr = in6addr_loopback
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
    precondition(bindResult == 0, "bind() failed")
    precondition(listen(fd, 8) == 0, "listen() failed")

    var bound = sockaddr_in6()
    var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
    withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = getsockname(fd, $0, &len)
        }
    }
    return (fd, UInt16(bigEndian: bound.sin6_port))
}

import Testing
@testable import BackendLauncher

extension ServiceStore {
    /// Fixture: store con il progetto "Skillera" pre-popolato — l'ex contenuto della
    /// migrazione legacy del primo avvio (rimossa il 2026-07-04: un'installazione nuova
    /// parte vuota). Decine di test di mutazione/bridge/template sono scritti contro
    /// questo progetto; la fixture ne preserva forma e valori esatti.
    @MainActor
    static func seededWithSkillera(fileURL: URL) -> ServiceStore {
        let store = ServiceStore(fileURL: fileURL)
        let services = ServiceConfig.legacyAll.map { config -> StoredService in
            let readiness: StoredReadiness
            if let port = config.port {
                readiness = StoredReadiness(kind: .port, port: port, marker: nil)
            } else {
                readiness = StoredReadiness(kind: .logMarker, port: nil, marker: "successfully started")
            }
            return StoredService(
                name: config.name,
                directory: ServiceConfig.projectRoot.appendingPathComponent(config.directory).path,
                command: config.command,
                readiness: readiness
            )
        }
        let profiles = ServiceConfig.legacyProfiles.map {
            StoredProfile(name: $0.name, serviceNames: $0.serviceNames)
        }
        let project = StoredProject(
            name: "Skillera",
            services: services,
            profiles: profiles,
            infraCheck: StoredInfraCheck(label: "NATS", port: ServiceConfig.natsPort)
        )
        // Append diretto + save, come faceva la migrazione (addProject non basta:
        // vogliamo servizi/profili/infra già popolati in un colpo).
        store.replaceProject(project)  // no-op se assente…
        if !store.projects.contains(where: { $0.id == project.id }) {
            try? store.addProject(named: project.name)
            store.replaceProject(project)
        }
        store.save()
        return store
    }
}

/// Mini responder HTTP su 127.0.0.1 (porta dal kernel) per i test del health check:
/// accetta connessioni in un thread dedicato e risponde sempre con lo status dato e body
/// vuoto. Chiudere con `close(fd)` — l'accept fallisce e il thread esce da solo.
func makeHTTPResponder(status: Int) -> (fd: Int32, port: UInt16) {
    let listener = makeTCPListener()
    Thread.detachNewThread {
        while true {
            let conn = accept(listener.fd, nil, nil)
            guard conn >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(conn, &buffer, buffer.count)  // consuma la request, contenuto irrilevante
            let response = "HTTP/1.1 \(status) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = response.withCString { write(conn, $0, strlen($0)) }
            close(conn)
        }
    }
    return listener
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
