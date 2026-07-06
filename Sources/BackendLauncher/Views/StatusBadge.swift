import SwiftUI

extension Color {
    /// Parser di un colore da stringa esadecimale "#RRGGBB" (con o senza "#"), usato per
    /// `StoredProject.accentColorHex`. Pura: nessuna dipendenza da NSColor/UIColor dinamici,
    /// nessun supporto ad alpha o forme abbreviate ("#RGB") — non ci servono, i preset del
    /// color picker sono tutti "#RRGGBB" a 6 cifre. Input non conforme (lunghezza sbagliata,
    /// caratteri non esadecimali) → `nil`, mai un colore "a caso".
    init?(hex: String) {
        var chars = hex
        if chars.hasPrefix("#") { chars.removeFirst() }
        guard chars.count == 6, let value = UInt32(chars, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

extension ServiceStatus {
    var label: String {
        switch self {
        case .stopped: return "fermo"
        case .starting: return "avvio…"
        case .running: return "in esecuzione"
        case .stopping: return "arresto…"
        // Exit 0 non richiesto dall'utente non è un vero crash (nessun errore, il processo si
        // è solo fermato da solo) — label/colore più neutri di un vero crash, che resta rosso.
        case .crashed(0): return "terminato (exit 0)"
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
        case .crashed(0): return .orange
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

/// Pallino di stato, pulsante durante le transizioni. Durante `.starting`, se il
/// chiamante passa `startedAt`, un anello attorno al pallino mostra il progresso
/// rispetto alla durata dell'avvio precedente (`expectedDuration`) — o un arco che
/// gira se non c'è ancora uno storico.
struct StatusDot: View {
    let status: ServiceStatus
    var startedAt: Date? = nil
    var expectedDuration: TimeInterval? = nil
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .frame(width: 12, height: 12)
            .shadow(color: status.color.opacity(status == .running || status.isPulsing ? 0.55 : 0),
                    radius: pulse ? 6 : 3)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: status)
            .animation(status.isPulsing
                       ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .overlay { startupRing }
            .onAppear { pulse = status.isPulsing }
            .onChange(of: status.isPulsing) { _, pulsing in pulse = pulsing }
            .accessibilityLabel("Stato: \(status.label)")
    }

    @ViewBuilder
    private var startupRing: some View {
        if status == .starting, let startedAt {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                if let expected = expectedDuration, expected > 0.5 {
                    // Storico disponibile: anello che si riempie ("di solito ci mette Xs").
                    Circle()
                        .trim(from: 0, to: min(elapsed / expected, 1))
                        .stroke(Color.yellow.opacity(0.9),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 19, height: 19)
                } else {
                    // Nessuno storico: arco indeterminato che ruota.
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.yellow.opacity(0.9),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(elapsed * 240))
                        .frame(width: 19, height: 19)
                }
            }
        }
    }
}

/// Pillola compatta per metriche (uptime, CPU/RAM) condivisa tra dashboard e Focus.
/// `accessibilityLabel`, se non vuota, sostituisce la lettura VoiceOver di default (che
/// altrimenti leggerebbe solo le cifre di `content`, es. "12:34", senza dire a cosa si
/// riferiscono) — default "" per compatibilità con i chiamanti esistenti che non lo passano.
struct MetricPill<Content: View>: View {
    let icon: String
    var accessibilityLabel: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        Label {
            content()
        } icon: {
            Image(systemName: icon)
                .imageScale(.small)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .foregroundStyle(.secondary)
        .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }
}

/// Applica `.accessibilityLabel` solo se `label` non è vuota — vive come `ViewModifier`
/// separato invece di un `if/else` inline perché i due rami di un `if` su una `View` con
/// `@ViewBuilder` avrebbero tipi opachi diversi (`.accessibilityLabel` vs identità), cosa che
/// `ViewModifier` evita restituendo sempre lo stesso tipo concreto.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if label.isEmpty {
            content
        } else {
            content.accessibilityLabel(label)
        }
    }
}

/// Spia infrastruttura per la toolbar (storicamente "NATS", ora parametrica: mostra la
/// spia del progetto selezionato). Default legacy per compatibilità con i chiamanti storici.
struct NATSIndicator: View {
    let up: Bool
    var label: String = "NATS"
    var port: UInt16 = 4222

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((up ? Color.green : Color.red).gradient)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .fixedSize()
        .help(up ? "\(label) raggiungibile su localhost:\(port)"
                 : "\(label) NON raggiungibile (localhost:\(port)) — i backend non comunicano")
        .accessibilityLabel(up ? "\(label) raggiungibile su localhost \(port)"
                               : "\(label) non raggiungibile su localhost \(port), i backend non comunicano")
    }
}
