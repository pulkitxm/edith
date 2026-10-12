import Foundation
import Testing

@Suite struct BlitzTreeEditorOwnershipTests {
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
                range: admission.upperBound..<configuration.endIndex))
        #expect(admission.lowerBound < rejection.lowerBound)
        #expect(rejection.lowerBound < installation.lowerBound)
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        #expect(try branch("stopUI", in: source).contains("stopUI()"))
        let suspended = try #require(configuration.range(of: "guard !commandsSuspended"))
        let suspendedRejection = try #require(
            configuration.range(of: "return [\"ok\": false] as NSDictionary"))
        #expect(suspended.lowerBound < suspendedRejection.lowerBound)
        #expect(suspendedRejection.lowerBound < admission.lowerBound)
        #expect(try branch("stop", in: source).contains("beginResourceStop()"))
        let teardown = try function("private func stopUI()", in: source)
        #expect(teardown.contains("TextEditingCommands.shutdown()"))
        #expect(teardown.contains("invalidate()"))
        #expect(teardown.contains("await model?.shutdown()"))
        let resourceStop = try function("private func beginResourceStop()", in: source)
        let reuse = try #require(
            resourceStop.range(of: "if let resourceStop { return resourceStop }"))
        let drain = try #require(resourceStop.range(of: "let drain = beginCommandDrain()"))
        let stopUI = try #require(resourceStop.range(of: "stopUI()"))
        let awaitDrain = try #require(resourceStop.range(of: "await drain.value"))
        let commands = try #require(resourceStop.range(of: "await commands.shutdownAndWait()"))
        let owner = try #require(resourceStop.range(of: "await owner?.shutdown()"))
        #expect(reuse.lowerBound < drain.lowerBound)
        #expect(drain.lowerBound < stopUI.lowerBound)
        #expect(stopUI.lowerBound < awaitDrain.lowerBound)
        #expect(awaitDrain.lowerBound < commands.lowerBound)
        #expect(commands.lowerBound < owner.lowerBound)
        let preparation = try function("func prepareToStop(completion:", in: source)
        let begin = try #require(preparation.range(of: "let stop = beginResourceStop()"))
        let awaitStop = try #require(preparation.range(of: "await stop.value"))
        let completion = try #require(preparation.range(of: "completion()"))
        #expect(begin.lowerBound < awaitStop.lowerBound)
        #expect(awaitStop.lowerBound < completion.lowerBound)
    }

    private func function(_ signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature))
        let end = try #require(
            source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
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
