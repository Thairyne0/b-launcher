import Foundation

/// Stato di un backend, derivato da fatti osservabili — nessuna macchina a stati nascosta.
enum ServiceStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case crashed(exitCode: Int32)
    case external   // porta aperta ma il processo non è nostro

    static func derive(processAlive: Bool, portOpen: Bool,
                       stopRequested: Bool, lastExitCode: Int32?) -> ServiceStatus {
        if processAlive {
            if stopRequested { return .stopping }
            return portOpen ? .running : .starting
        }
        if let code = lastExitCode {
            return stopRequested ? .stopped : .crashed(exitCode: code)
        }
        return portOpen ? .external : .stopped
    }
}
