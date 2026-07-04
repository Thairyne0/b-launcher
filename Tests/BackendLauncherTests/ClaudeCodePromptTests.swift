import Foundation
import Testing
@testable import BackendLauncher

@Suite struct ClaudeCodePromptTests {
    @Test func promptContainsSchemaKeys() {
        let prompt = ClaudeCodePrompt.make()

        #expect(prompt.contains("templateVersion"))
        #expect(prompt.contains("relativeDirectory"))
        #expect(prompt.contains("readiness"))
        #expect(prompt.contains("\"port\""))
        #expect(prompt.contains("\"logMarker\""))
        #expect(prompt.contains("\"processAlive\""))
        #expect(prompt.contains(".blauncher.json"))
    }

    @Test func promptSuggestsOneClickDeepLinkCommand() {
        let prompt = ClaudeCodePrompt.make()

        #expect(prompt.contains("blauncher://import"))
        #expect(prompt.contains("open \"blauncher://import?file="))
        #expect(prompt.contains("&root="))
        // Fallback esistente preservato: se l'utente preferisce, può ancora dare il percorso a voce.
        #expect(prompt.contains("dimmi"))
    }

    @Test func promptForbidsTraversal() {
        let prompt = ClaudeCodePrompt.make()

        #expect(prompt.contains("\"..\""))
    }

    @Test func promptIsStable() {
        let prompt = ClaudeCodePrompt.make()

        #expect(!prompt.isEmpty)
        #expect(prompt.count > 800)
    }

    /// Consistenza CRITICA schema <-> prompt: l'esempio JSON incollato qui (fixture, copiato
    /// letteralmente dal prompt) deve decodificare come `ProjectTemplate` valido tramite
    /// `ProjectTemplateCodec.decode`. Se lo schema di `ProjectTemplate`/`StoredReadiness`
    /// cambia senza aggiornare il prompt (o viceversa), questo test rompe la build invece di
    /// lasciare che il prompt suggerisca un JSON non più importabile.
    @Test func exampleJSONFromPromptDecodesAsValidProjectTemplate() throws {
        let exampleJSON = """
        {
          "templateVersion": 1,
          "name": "NomeProgetto",
          "services": [
            {
              "name": "gateway",
              "relativeDirectory": "PERCORSO-RELATIVO",
              "command": "npm run start:dev",
              "readiness": {"kind": "port", "port": 4000, "marker": null}
            }
          ],
          "profiles": [
            {"name": "Tutti", "serviceNames": ["gateway"]}
          ],
          "infraCheck": {"label": "NATS", "port": 4222}
        }
        """
        let data = try #require(exampleJSON.data(using: .utf8))

        let template = try ProjectTemplateCodec.decode(data)

        #expect(template.templateVersion == 1)
        #expect(template.name == "NomeProgetto")
        #expect(template.services.count == 1)
        let service = try #require(template.services.first)
        #expect(service.name == "gateway")
        #expect(service.relativeDirectory == "PERCORSO-RELATIVO")
        #expect(service.command == "npm run start:dev")
        #expect(service.readiness == StoredReadiness(kind: .port, port: 4000, marker: nil))
        #expect(template.profiles == [StoredProfile(name: "Tutti", serviceNames: ["gateway"])])
        #expect(template.infraCheck == StoredInfraCheck(label: "NATS", port: 4222))

        // Bonus: l'esempio embeddato nel prompt deve essere un sottostringa esatta del prompt
        // stesso (byte-per-byte, indentazione inclusa) — altrimenti il prompt e questa fixture
        // sono già divergenti anche se lo schema regge.
        let prompt = ClaudeCodePrompt.make()
        #expect(prompt.contains(exampleJSON))
    }
}
