import Foundation
import Testing
@testable import EdithStudio

@Suite struct StudioInertEnvironmentTests {
    @Test func explicitEmptyResolverNeverFallsBackToSearchPathsOrSystemAvailability() throws {
        let environment = StudioEnvironment.detect(
            path: "/fixture-toolbin",
            resolve: { _ in nil }, allowsSearchFallback: false, modelAvailable: { false },
            translationAvailable: false)
        #expect(environment.ffmpeg == nil)
        #expect(environment.ffprobe == nil)
        #expect(environment.qpdf == nil)
        #expect(!environment.appleIntelligenceAvailable)
        #expect(!environment.satisfies(.translation))
        #expect(throws: (any Error).self) { try environment.require(.ffmpeg) }
    }

    @Test func explicitSyntheticVersionStubNeverEnablesOtherTools() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("qpdf")
        try Data("synthetic-qpdf-version-1".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let versionRunner: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
        #expect(try versionRunner(stub) == "synthetic-qpdf-version-1")
        let environment = StudioEnvironment.detect(
            path: root.path,
            resolve: { $0 == "qpdf" ? stub : nil }, allowsSearchFallback: false,
            modelAvailable: { false }, translationAvailable: false)
        #expect(environment.qpdf == stub)
        #expect(environment.ffmpeg == nil)
        #expect(environment.ffprobe == nil)
        #expect(!environment.appleIntelligenceAvailable)
    }
}
