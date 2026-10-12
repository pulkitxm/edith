import Foundation
import Testing

@Suite struct LaTeXEditorOwnershipTests {
    @Test func onlyValidatedUIConfigurationCanOwnTheEditorMonitor() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runtime.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let startup = try branch("start", in: source)
        #expect(!startup.contains("TextEditingCommands"))
        let configuration = try branch("configureUI", in: source)
        let admission = try #require(
            configuration.range(of: "ExtensionUIConfiguration(context: input)"))
        let installation = try #require(configuration.range(of: "TextEditingCommands.install()"))
        let rejection = try #require(
            configuration.range(
                of: "return [\"ok\": false] as NSDictionary",
                range: admission.upperBound..<installation.lowerBound))
        #expect(admission.lowerBound < rejection.lowerBound)
        #expect(rejection.lowerBound < installation.lowerBound)
        let validation = configuration[admission.upperBound..<rejection.lowerBound]
        #expect(validation.contains("configuration.extensionID == \"latex\""))
        #expect(validation.contains("let client = configuration.engineClient"))
        #expect(validation.contains("Self.hasEditorResources"))
        #expect(
            configuration.components(separatedBy: "return [\"ok\": false] as NSDictionary")
                .count == 3)
        #expect(!configuration[installation.upperBound...].contains("return [\"ok\": false]"))
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        #expect(try branch("stopUI", in: source).contains("stopUI()"))
        #expect(try branch("stop", in: source).contains("stopUI()"))
        let stop = try #require(source.range(of: "private func stopUI()"))
        let teardown = source[stop.lowerBound...]
        #expect(teardown.contains("TextEditingCommands.shutdown()"))
        #expect(teardown.contains("invalidate()"))
        let preparation = try #require(source.range(of: "func prepareToStop(completion:"))
        let end = try #require(
            source.range(of: "\n    }", range: preparation.upperBound..<source.endIndex))
        #expect(source[preparation.upperBound..<end.lowerBound].contains("stopUI()"))
    }

    private func branch(_ operation: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "case \"" + operation + "\":", options: []))
        let end =
            source.range(of: "\n        case ", range: start.upperBound..<source.endIndex)?
            .lowerBound
            ?? source.endIndex
        return source[start.upperBound..<end]
    }
}
