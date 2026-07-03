import SwiftUI

extension ServiceStatus {
    var label: String {
        switch self {
        case .stopped: return "fermo"
        case .starting: return "avvio…"
        case .running: return "in esecuzione"
        case .stopping: return "arresto…"
        case .crashed(let code): return "crash (exit \(code))"
        case .external: return "attivo fuori dal launcher"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .stopping: return .orange
        case .crashed: return .red
        case .external: return .blue
        }
    }

    var isPulsing: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }
}

/// Pallino di stato, pulsante durante le transizioni.
struct StatusDot: View {
    let status: ServiceStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .frame(width: 11, height: 11)
            .shadow(color: status.color.opacity(0.6), radius: pulse ? 6 : 2)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .animation(status.isPulsing
                       ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .onAppear { pulse = status.isPulsing }
            .onChange(of: status.isPulsing) { _, pulsing in pulse = pulsing }
    }
}

/// Spia NATS per la toolbar.
struct NATSIndicator: View {
    let up: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((up ? Color.green : Color.red).gradient)
                .frame(width: 9, height: 9)
            Text("NATS")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .help(up ? "NATS raggiungibile su localhost:4222"
                 : "NATS NON raggiungibile (localhost:4222) — i backend non comunicano")
    }
}
