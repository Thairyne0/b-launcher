import Foundation

/// Rileva un crash loop: almeno `threshold` crash veri (exit ≠ 0 non richiesto) negli
/// ultimi `windowSeconds`. Logica pura con date esplicite (testabile senza aspettare
/// tempo reale); vive per-servizio dentro `ServiceController`.
struct CrashLoopDetector {
    var threshold = 3
    var windowSeconds: TimeInterval = 120

    private var crashDates: [Date] = []

    mutating func recordCrash(at date: Date) {
        crashDates.append(date)
        // Pota lo storico fuori finestra: il detector vive quanto il controller,
        // non deve accumulare per sempre.
        crashDates.removeAll { date.timeIntervalSince($0) > windowSeconds }
    }

    /// Da chiamare quando l'utente riprende il controllo (stop manuale) o il servizio
    /// si dimostra stabile: il prossimo crash riparte da zero.
    mutating func reset() {
        crashDates.removeAll()
    }

    func recentCrashCount(at date: Date) -> Int {
        crashDates.filter { date.timeIntervalSince($0) <= windowSeconds }.count
    }

    func isLooping(at date: Date) -> Bool {
        recentCrashCount(at: date) >= threshold
    }
}
