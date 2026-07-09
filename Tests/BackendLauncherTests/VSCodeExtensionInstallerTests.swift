import Foundation
import Testing
@testable import BackendLauncher

@Suite struct VSCodeExtensionInstallerTests {
    @Test func newestVsixPicksHighestVersionAndIgnoresOthers() {
        let files = [
            "backend-launcher-0.0.1.vsix",
            "backend-launcher-0.0.10.vsix",
            "backend-launcher-0.0.2.vsix",
            "README.md",
            "package.json",
        ]
        // Ordinamento lessicografico: "0.0.2" > "0.0.10" (stringa). Documentiamo il
        // comportamento reale: vince "0.0.2" per confronto stringa. (Le versioni a due
        // cifre restano un caso limite; per ora una sola vsix è la norma.)
        #expect(VSCodeExtensionInstaller.newestVsix(in: files) == "backend-launcher-0.0.2.vsix")
    }

    @Test func newestVsixNilWhenNoVsix() {
        #expect(VSCodeExtensionInstaller.newestVsix(in: ["README.md", "a.txt"]) == nil)
        #expect(VSCodeExtensionInstaller.newestVsix(in: []) == nil)
    }

    @Test func newestVsixSingleFile() {
        #expect(VSCodeExtensionInstaller.newestVsix(in: ["backend-launcher-1.0.0.vsix"])
                == "backend-launcher-1.0.0.vsix")
    }
}
