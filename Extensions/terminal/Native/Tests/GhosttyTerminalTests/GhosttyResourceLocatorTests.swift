import Foundation
import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyResourceLocatorTests {
    @Test func bundledResourcesContainShellIntegrationAndTerminfo() throws {
        let locator = GhosttyResourceLocator()
        let ghostty = try #require(locator.bundledResourceDirectory())
        let root = ghostty.deletingLastPathComponent()

        #expect(ghostty.lastPathComponent == "ghostty")
        #expect(
            FileManager.default.fileExists(
                atPath: ghostty.appendingPathComponent("shell-integration/bash/ghostty.bash").path))
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("terminfo/78/xterm-ghostty").path))
    }

    @Test func validatedResourcesConfigureTheEnvironment() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeValidResources(at: root)

        var capturedName: String?
        var capturedValue: String?
        let configured = GhosttyResourceLocator().configureEnvironment(from: root) { name, value in
            capturedName = name
            capturedValue = value
            return true
        }

        #expect(configured == root.appendingPathComponent("ghostty", isDirectory: true))
        #expect(capturedName == GhosttyResourceLocator.environmentName)
        #expect(capturedValue == configured?.path)
    }

    @Test func incompleteResourcesDoNotChangeTheEnvironment() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var invoked = false
        let configured = GhosttyResourceLocator().configureEnvironment(from: root) { _, _ in
            invoked = true
            return true
        }

        #expect(configured == nil)
        #expect(!invoked)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyResourceLocatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeValidResources(at root: URL) throws {
        let shellIntegration = root.appendingPathComponent(
            "ghostty/shell-integration", isDirectory: true)
        let terminfo = root.appendingPathComponent("terminfo/78", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shellIntegration, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: terminfo, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: terminfo.appendingPathComponent("xterm-ghostty").path, contents: Data())
    }
}
