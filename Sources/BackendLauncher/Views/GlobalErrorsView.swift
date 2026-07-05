import SwiftUI

/// Pannello errori globale: le righe di errore di TUTTI i servizi in un'unica lista
/// ordinata per tempo (più recenti in alto). Per il debugging "a cascata": quando il
/// gateway sputa 500, qui si vede subito quale servizio a valle sta fallendo, senza
/// aprire i terminali uno a uno. Click su una riga → pannello del servizio.
struct GlobalErrorsView: View {
    var model: AppModel
    var onOpenService: (String) -> Void

    var body: some View {
        let errors = model.globalErrors
        Group {
            if errors.isEmpty {
                ContentUnavailableView("Nessun errore",
                                       systemImage: "checkmark.circle",
                                       description: Text("Le righe di errore di tutti i backend compariranno qui, ordinate per tempo."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(errors) { entry in
                            errorRow(entry)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func errorRow(_ entry: AppModel.GlobalErrorEntry) -> some View {
        Button {
            onOpenService(entry.serviceID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.line.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.serviceName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.18), in: .capsule)
                    .foregroundStyle(.red)
                Text(entry.line.text)
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
        .help("Apri il terminale di \(entry.serviceName)")
    }
}
