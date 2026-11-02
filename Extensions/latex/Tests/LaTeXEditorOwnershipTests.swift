import Foundation
import Testing

@Suite struct LaTeXEditorOwnershipTests {
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
        let validation = configuration[admission.upperBound..<rejection.lowerBound]
        #expect(validation.contains("Self.hasEditorResources"))
        #expect(configuration.components(separatedBy: "return false").count == 2)
        #expect(!configuration[installation.upperBound...].contains("return false"))
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        let stopUI = try body("func stopUI()", in: source)
        #expect(stopUI.contains("TextEditingCommands.shutdown()"))
        #expect(stopUI.contains("invalidate()"))
        #expect(try body("func teardown()", in: source).contains("stopUI()"))
    }

    private func body(_ signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let end = try #require(
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }
}
