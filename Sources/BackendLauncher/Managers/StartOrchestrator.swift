import Foundation

/// Ordina l'avvio di un insieme di servizi rispettando `startAfter`: logica pura,
/// nessun processo — l'esecuzione (start + attesa readiness) vive in AppModel.
enum StartOrchestrator {
    /// Ondate di avvio: ogni ondata dipende solo da servizi delle ondate precedenti.
    /// L'ordine DENTRO un'ondata rispecchia l'ordine dell'input (stabile).
    /// Dipendenze verso nomi non presenti nell'insieme vanno filtrate dal chiamante.
    /// Ciclo (incluso auto-dipendenza) → `nil`: il chiamante fa fallback piatto.
    static func waves(services: [(name: String, startAfter: [String])]) -> [[String]]? {
        var remaining = services
        var done = Set<String>()
        var result: [[String]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { service in
                service.startAfter.allSatisfy { done.contains($0) }
            }
            guard !ready.isEmpty else { return nil }  // nessun progresso possibile: ciclo
            result.append(ready.map(\.name))
            done.formUnion(ready.map(\.name))
            remaining.removeAll { done.contains($0.name) }
        }
        return result
    }
}
