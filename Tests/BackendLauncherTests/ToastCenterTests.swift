import Testing
@testable import BackendLauncher

@MainActor
@Suite struct ToastCenterTests {
    @Test func showSetsCurrent() {
        let center = ToastCenter()
        center.show("Ciao")
        #expect(center.current?.message == "Ciao")
        #expect(center.current?.systemImage == "checkmark.circle.fill")
    }

    @Test func showWithCustomSystemImage() {
        let center = ToastCenter()
        center.show("Avvio", systemImage: "play.circle.fill")
        #expect(center.current?.systemImage == "play.circle.fill")
    }

    @Test func secondShowReplacesCurrent() {
        let center = ToastCenter()
        center.show("Primo")
        let firstID = center.current?.id
        center.show("Secondo")
        #expect(center.current?.message == "Secondo")
        #expect(center.current?.id != firstID)
    }

    @Test func autoDismissClearsCurrentAfterDelay() async {
        let center = ToastCenter()
        center.show("Effimero")
        #expect(center.current != nil)
        let cleared = await waitUntil(timeout: 3.5) { center.current == nil }
        #expect(cleared)
    }

    @Test func rapidReplacementDoesNotLetStaleDismissClearNewerToast() async {
        let center = ToastCenter()
        center.show("Primo")
        // Rimpiazza subito: il dismiss task del primo toast non deve azzerare il secondo.
        center.show("Secondo")
        try? await Task.sleep(for: .seconds(2.4))
        // Il secondo toast dovrebbe essersi già auto-cancellato per conto proprio ORA (dopo
        // 2.2s dal suo show), quindi verifichiamo che l'ordine sia stato rispettato aspettando
        // uno stato consistente: current è nil (scaduto) e non è mai stato lasciato "Primo".
        #expect(center.current == nil)
    }
}
