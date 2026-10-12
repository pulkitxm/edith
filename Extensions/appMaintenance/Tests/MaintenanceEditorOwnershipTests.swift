import Foundation
import Testing

@Suite struct MaintenanceEditorOwnershipTests {
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
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        try requireOrdered(
            [
                "guard !commandsSuspended, uiDrains.count < 8",
                "return [\"ok\": false] as NSDictionary",
                "ExtensionUIConfiguration(context: input)",
                "configuration.extensionID == \"appMaintenance\", !configuration.uiOnly",
                "let client = configuration.engineClient",
                "guard configurePresentation(input, client: client)",
                "TextEditingCommands.install()",
            ], in: configuration)
        #expect(try branch("stopUI", in: source).contains("stopUI()"))
        #expect(try branch("stop", in: source).contains("beginResourceStop()"))
        let presentation = try function("func configurePresentation(", in: source)
        try requireOrdered(
            [
                "guard !stopped", "input[\"extensionID\"] as? String == \"appMaintenance\"",
                "input[\"uiOnly\"] as? Bool == false",
                "input[\"presentationID\"] as? String == client.presentationID.uuidString",
                "guard !commandsSuspended, uiDrains.count < 8", "stopUI()", "uiClient = client",
            ], in: presentation)
        let teardown = try function("private func stopUI()", in: source)
        #expect(teardown.contains("TextEditingCommands.shutdown()"))
        #expect(teardown.contains("invalidate()"))
        try requireOrdered(
            [
                "TextEditingCommands.shutdown()", "let model = uiModel",
                "let settings = settingsModel", "settings?.stop()",
                "model?.cancelPendingCommands()", "uiDrains[id] = Task",
                "await model?.shutdown()", "await settings?.stopAndWait()",
                "uiModel = nil; settingsModel = nil", "uiClient?.invalidate()",
            ], in: teardown)
        let resourceStop = try function("private func beginResourceStop()", in: source)
        try requireOrdered(
            [
                "if let resourceStop { return resourceStop }", "let owner = model",
                "let drain = beginCommandDrain()", "stopUI()", "stopped = true", "model = nil",
                "await drain.value", "await commands.shutdownAndWait()",
                "await owner?.shutdown()", "resourceStop = task", "return task",
            ], in: resourceStop)
        let commandDrain = try function("private func beginCommandDrain()", in: source)
        try requireOrdered(
            [
                "let owner = model", "let uiOwner = uiModel", "let settingsOwner = settingsModel",
                "let streams = cliStreams", "commandsSuspended = true", "commands.suspend()",
                "if let commandDrain { return commandDrain }", "owner?.cancelPendingCommands()",
                "uiOwner?.cancelPendingCommands()", "settingsOwner?.stop()", "streams?.stop()",
                "await commands.suspendAndWait()", "await owner?.cancelAndWait()",
                "await uiOwner?.cancelAndWait()", "await settingsOwner?.stopAndWait()",
                "await streams?.stopAndWait()",
                "while let task = uiDrains.values.first { await task.value }",
                "commandDrain = task", "return task",
            ], in: commandDrain)
        let preparation = try function("func prepareToStop(completion:", in: source)
        try requireOrdered(
            ["let stop = beginResourceStop()", "await stop.value", "completion()"],
            in: preparation)
        let suspension = try function("func suspendCommands(completion:", in: source)
        try requireOrdered(
            [
                "let drain = beginCommandDrain()", "await drain.value", "await resourceStop?.value",
                "completion()",
            ], in: suspension)
    }

    private func requireOrdered(_ tokens: [String], in source: Substring) throws {
        let positions = try tokens.map { token in
            try #require(source.range(of: token)).lowerBound
        }
        for index in positions.indices.dropFirst() {
            #expect(positions[index - 1] < positions[index])
        }
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
