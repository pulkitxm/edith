import Foundation
import Testing

@Suite struct BlitzTreeEditorOwnershipTests {
    @Test func onlyValidatedUIConfigurationCanOwnTheEditorMonitor() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runtime.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(!(try body("func start()", in: source)).contains("TextEditingCommands"))
        let configuration = try body("func configureUI(", in: source)
        let admission = try #require(configuration.range(of: "configuration.engineClient"))
        let rejection = try #require(configuration.range(of: "return false"))
        let installation = try #require(configuration.range(of: "TextEditingCommands.install()"))
        #expect(admission.lowerBound < rejection.lowerBound)
        #expect(rejection.lowerBound < installation.lowerBound)
        #expect(configuration.contains("uiDrains.count < 8"))
        #expect(source.contains("var allowsUIDuringRetirement: Bool { true }"))
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        #expect(try body("func stopUI()", in: source).contains("releaseUI()"))
        let teardown = try body("func teardown()", in: source)
        #expect(teardown.contains("releaseUI()"))
        #expect(teardown.contains("await owner?.shutdown()"))
        let release = try body("func releaseUI()", in: source)
        #expect(release.contains("TextEditingCommands.shutdown()"))
        #expect(release.contains("invalidate()"))
        #expect(release.contains("await stopping?.shutdown()"))
    }

    private func body(_ signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let end = try #require(
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }
}
