import Foundation
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct DeepLinkCenterTests {
    /// File `.json` temporaneo reale: `handle(url:)` valida l'esistenza sul filesystem prima
    /// di accettare il link, quindi i test non possono usare path fittizi mai creati.
    private func tempJSONFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-deeplink-tests-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        return url
    }

    @Test func handlesValidImportLinkWithFileOnly() throws {
        let center = DeepLinkCenter()
        let fileURL = try tempJSONFile()
        let url = URL(string: "blauncher://import?file=\(fileURL.path)")!

        center.handle(url: url)

        #expect(center.pendingImport?.fileURL.path == fileURL.path)
        #expect(center.pendingImport?.rootURL == nil)
    }

    @Test func handlesValidImportLinkWithFileAndRoot() throws {
        let center = DeepLinkCenter()
        let fileURL = try tempJSONFile()
        let rootPath = "/Users/dev/Skillera"
        let url = URL(string: "blauncher://import?file=\(fileURL.path)&root=\(rootPath)")!

        center.handle(url: url)

        #expect(center.pendingImport?.fileURL.path == fileURL.path)
        #expect(center.pendingImport?.rootURL?.path == rootPath)
    }

    @Test func percentEncodedPathsAreDecoded() throws {
        // Simula un path con spazi (percent-encoded nell'URL, es. "/Users/dev/My Repo").
        let dirWithSpace = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher deeplink dir \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirWithSpace, withIntermediateDirectories: true)
        let fileURL = dirWithSpace.appendingPathComponent("template.blauncher.json")
        try Data("{}".utf8).write(to: fileURL)

        var components = URLComponents()
        components.scheme = "blauncher"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "file", value: fileURL.path)]
        let url = try #require(components.url)

        let center = DeepLinkCenter()
        center.handle(url: url)

        #expect(center.pendingImport?.fileURL.path == fileURL.path)
    }

    @Test func rejectsWrongScheme() throws {
        let center = DeepLinkCenter()
        let url = URL(string: "https://import?file=/tmp/x.json")!

        center.handle(url: url)

        #expect(center.pendingImport == nil)
    }

    @Test func rejectsWrongHost() throws {
        let center = DeepLinkCenter()
        let fileURL = try tempJSONFile()
        let url = URL(string: "blauncher://export?file=\(fileURL.path)")!

        center.handle(url: url)

        #expect(center.pendingImport == nil)
    }

    @Test func rejectsMissingFileParam() throws {
        let center = DeepLinkCenter()
        let url = URL(string: "blauncher://import")!

        center.handle(url: url)

        #expect(center.pendingImport == nil)
    }

    @Test func rejectsNonexistentFile() throws {
        let center = DeepLinkCenter()
        let missingPath = "/tmp/blauncher-does-not-exist-\(UUID().uuidString).json"
        let url = URL(string: "blauncher://import?file=\(missingPath)")!

        center.handle(url: url)

        #expect(center.pendingImport == nil)
    }

    @Test func rejectsNonJSONFile() throws {
        let center = DeepLinkCenter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-deeplink-tests-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: url)
        let link = URL(string: "blauncher://import?file=\(url.path)")!

        center.handle(url: link)

        #expect(center.pendingImport == nil)
    }

    @Test func rejectsDirectoryAsFileParam() throws {
        let center = DeepLinkCenter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-deeplink-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(string: "blauncher://import?file=\(dir.path)")!

        center.handle(url: url)

        #expect(center.pendingImport == nil)
    }

    @Test func emptyRootParamIsTreatedAsNil() throws {
        let center = DeepLinkCenter()
        let fileURL = try tempJSONFile()
        let url = URL(string: "blauncher://import?file=\(fileURL.path)&root=")!

        center.handle(url: url)

        #expect(center.pendingImport?.rootURL == nil)
    }
}
