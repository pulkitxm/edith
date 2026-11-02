import Foundation
import Testing

@Suite struct MaintenanceEditorOwnershipTests {
    @Test func onlyValidatedUIConfigurationCanOwnTheEditorMonitor() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runtime.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(!(try function("func start()", in: source)).contains("TextEditingCommands"))
        let configuration = try function("func configureUI(", in: source)
        try requireOrdered(
            [
                "guard uiDrains.count < 8, !configuration.uiOnly",
                "let client = configuration.engineClient",
                "let location = configuration.location", "let section = configuration.section",
                "return false", "releaseUI()", "uiClient = client", "uiLocation = location",
                "uiSection = section", "TextEditingCommands.install()",
            ], in: configuration)
        #expect(source.components(separatedBy: "TextEditingCommands.install()").count == 2)
        #expect(
            try function("func stopUI(for presentation: UUID?)", in: source).contains("releaseUI()")
        )
        let teardown = try function("func teardown()", in: source)
        try requireOrdered(
            ["let owner = model", "releaseUI()", "model = nil", "await owner?.shutdown()"],
            in: teardown)
        let release = try function("private func releaseUI()", in: source)
        #expect(release.contains("TextEditingCommands.shutdown()"))
        #expect(release.contains("invalidate()"))
        try requireOrdered(
            [
                "ExtensionUIResources.cleanup(of: runtime", "TextEditingCommands.shutdown()",
                "let model = uiModel", "let settings = settingsModel", "settings?.stop()",
                "model?.cancelPendingCommands()", "let task = Task",
                "await model?.shutdown()", "await settings?.stopAndWait()", "uiDrains[id] = task",
                "uiModel = nil",
                "settingsModel = nil", "uiClient?.invalidate()",
            ], in: release)
        let cancellation = try function("func cancelPendingWork()", in: source)
        try requireOrdered(
            [
                "model?.cancelPendingCommands()", "uiModel?.cancelPendingCommands()",
                "settingsModel?.stop()", "cliStreams?.stop()",
            ], in: cancellation)
        let drain = try function("func drain()", in: source)
        try requireOrdered(
            [
                "await model?.cancelAndWait()", "await uiModel?.cancelAndWait()",
                "await settingsModel?.stopAndWait()", "await cliStreams?.stopAndWait()",
                "while let task = uiDrains.values.first { await task.value }",
            ], in: drain)
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
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound]
    }
}
