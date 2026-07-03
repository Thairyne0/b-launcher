import Foundation
import Testing
@testable import BackendLauncher

@Suite struct LogFileWriterTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blauncher-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func appendsAndCreatesFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LogFileWriter(serviceName: "fake", directory: dir)
        writer.append("ciao\n")
        writer.sync()

        #expect(FileManager.default.fileExists(atPath: writer.fileURL.path))
        let contents = try? String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(contents?.contains("ciao") == true)
    }

    @Test func bannerFormat() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LogFileWriter(serviceName: "fake", directory: dir)
        writer.appendBanner("x")
        writer.sync()

        let contents = try? String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(contents?.contains("===== x =====") == true)
    }

    @Test func rotationMovesToOld() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LogFileWriter(serviceName: "fake", directory: dir, maxBytes: 64)
        let bigChunk = String(repeating: "a", count: 100) + "\n"
        writer.append(bigChunk)
        writer.sync()
        writer.append(bigChunk)
        writer.sync()

        let oldURL = dir.appendingPathComponent("fake.log.old")
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        let oldSize = (try? FileManager.default.attributesOfItem(atPath: oldURL.path)[.size] as? UInt64) ?? nil
        #expect((oldSize ?? 0) > 64)

        let freshSize = (try? FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.size] as? UInt64) ?? nil
        #expect((freshSize ?? 0) < (oldSize ?? 0))
    }
}
