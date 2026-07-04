import Foundation
import Testing
@testable import BackendLauncher

@Suite struct ServiceConfigTests {
    /// Il nome mostrato è ESATTAMENTE quello inserito dall'utente (o derivato dallo scanner):
    /// lo storico prefisso "skill" era un retaggio dei backend SkillLocale hardcoded e
    /// produceva assurdità tipo "skillprova" per un servizio chiamato "prova".
    @Test func displayNameIsTheUserProvidedName() {
        let config = ServiceConfig(name: "prova", directory: "prova", port: nil)
        #expect(config.displayName == "prova")

        let scanned = ServiceConfig(name: "skillgateway-be", directory: "SKILLGATEWAY-BE", port: 4000)
        #expect(scanned.displayName == "skillgateway-be")
    }
}
