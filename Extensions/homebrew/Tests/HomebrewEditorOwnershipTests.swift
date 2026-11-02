import Foundation
import Testing

@Suite struct HomebrewEditorOwnershipTests {
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
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        #expect(try body("func stopUI()", in: source).contains("releaseTextEditing()"))
        let teardown = try body("func teardown()", in: source)
        #expect(teardown.contains("releaseTextEditing()"))
        #expect(teardown.contains("invalidate()"))
        #expect(
            try body("func releaseTextEditing()", in: source).contains(
                "TextEditingCommands.shutdown()"))
    }

    private func body(_ signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let end = try #require(
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }
}
