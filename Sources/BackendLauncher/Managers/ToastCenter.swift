import SwiftUI
import Observation

/// Coda di toast di conferma azioni: HUD non intrusivo in basso al centro, per dare un
/// riscontro immediato di azioni "fire and forget" (avvia/ferma/riavvia, export, ecc.) senza
/// interrompere il flusso con un alert. Un solo toast alla volta: uno nuovo rimpiazza quello
/// corrente invece di accodarsi — coerente con l'uso previsto (conferme brevi, non una coda di
/// notifiche da smaltire).
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id: UUID
        let message: String
        let systemImage: String
    }

    private(set) var current: Toast?

    /// `Task` di auto-dismiss del toast corrente. Ogni nuova `show` cancella quello precedente
    /// e ne pianifica uno nuovo, guardato sull'id del toast: se nel frattempo un altro `show` ha
    /// già rimpiazzato `current`, il dismiss "in ritardo" non deve cancellare il toast più recente.
    private var dismissTask: Task<Void, Never>?

    /// Init non-privato: la UI usa sempre `.shared`, ma i test vogliono un'istanza isolata per
    /// non condividere stato tra `@Test` eseguiti in parallelo.
    init() {}

    func show(_ message: String, systemImage: String = "checkmark.circle.fill") {
        let toast = Toast(id: UUID(), message: message, systemImage: systemImage)
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            guard let self, self.current?.id == toast.id else { return }
            self.current = nil
        }
    }
}

/// HUD capsula glass in basso al centro che mostra `ToastCenter.shared.current`, se presente.
/// Vive in un file separato di layout logico ma insieme a `ToastCenter` per tenere insieme
/// stato e presentazione di una feature piccola e autocontenuta.
struct ToastOverlay: View {
    var center = ToastCenter.shared

    var body: some View {
        Group {
            if let toast = center.current {
                Label(toast.message, systemImage: toast.systemImage)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.snappy, value: center.current)
    }
}
