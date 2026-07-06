import SwiftUI

/// Pannello errori globale: le righe di errore di TUTTI i servizi in un'unica lista
/// ordinata per tempo (più recenti in alto). Per il debugging "a cascata": quando il
/// gateway sputa 500, qui si vede subito quale servizio a valle sta fallendo, senza
/// aprire i terminali uno a uno. Click su una riga → pannello del servizio.
struct GlobalErrorsView: View {
    var model: AppModel
    var onOpenService: (String) -> Void

    var body: some View {
        let groups = model.globalErrorGroups
        Group {
            if groups.isEmpty {
                ContentUnavailableView("Nessun errore",
                                       systemImage: "checkmark.circle",
                                       description: Text("Le righe di errore di tutti i backend compariranno qui, ordinate per tempo. Gli errori identici vengono raggruppati."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            errorRow(group)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func errorRow(_ group: AppModel.GlobalErrorGroup) -> some View {
        Button {
            onOpenService(group.serviceID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.lastReceivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(group.serviceName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.18), in: .capsule)
                    .foregroundStyle(.red)
                if group.count > 1 {
                    Text("×\(group.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: .capsule)
                        .foregroundStyle(.orange)
                        .help("\(group.count) occorrenze identiche — mostrata la più recente")
                        .contentTransition(.numericText())
                        .animation(.snappy, value: group.count)
                }
                Text(group.text)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .help("Apri il terminale di \(group.serviceName)")
    }
}
