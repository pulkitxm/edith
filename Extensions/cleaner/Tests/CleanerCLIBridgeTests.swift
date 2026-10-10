import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import CleanerExtension

@Suite(.serialized) @MainActor struct CleanerCLIBridgeTests {
    @Test func originalRootScanAndCleanPreviewUseRealScannerWithoutTrashing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "synthetic.cleaner.cli." + UUID().uuidString)
        let cache = root.appendingPathComponent("project/node_modules")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("fixture.bin")
        try Data(repeating: 9, count: 8192).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = try await CleanerCLIExecution.run(
            .init(arguments: ["scan", "--root", root.path, "--category", "nodeModules", "--json"]))
        #expect(
            scan.exitCode == 0 && scan.stderr.isEmpty && scan.stdout.contains("node_modules")
                && scan.stdout.contains("8192"))
        let preview = try await CleanerCLIExecution.run(
            .init(arguments: ["clean", "--root", root.path, "--category", "nodeModules", "--json"])
        )
        #expect(
            preview.exitCode == 0 && preview.stdout.contains("false")
                && FileManager.default.fileExists(atPath: file.path))
        for args in [
            ["categories", "--json"], ["ls", "--json"], ["clean", "--help"], ["drives", "--help"],
        ] {
            let reply = try await CleanerCLIExecution.run(.init(arguments: args))
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty && !reply.stdout.isEmpty)
        }
        let invalid = try await CleanerCLIExecution.run(
            .init(arguments: ["scan", "--category", "missing"]))
        #expect(invalid.exitCode == 3 && invalid.stdout.isEmpty && !invalid.stderr.isEmpty)
    }
    @Test func staleRemoteSelectionCannotChangeTheLatestEngineScan() async throws {
        let suite = "synthetic.cleaner.selection." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] },
                scan: { _, _, _ in
                    .init(categories: [
                        .init(
                            id: "synthetic", name: "Cache", detail: "Fixture",
                            items: [
                                .init(
                                    id: "item", name: "Cache",
                                    path: URL(fileURLWithPath: "/synthetic/cache"), sizeBytes: 8,
                                    selected: true)
                            ])
                    ])
                },
                clean: { _, _ in
                    Issue.record("No clean expected");
                    return .init(items: 0, requestedBytes: 0, reclaimedBytes: 0)
                }))
        let stale = model.previewToken
        _ = try await CleanerCommands.execute("cleaner.scan", payload: Data(), model: model)
        let action = CleanerUIAction(operation: "all", value: nil, item: nil, previewToken: stale)
        await #expect(throws: ExtensionPeerError.self) {
            try await CleanerUICommands.execute(
                "cleaner.ui.action", payload: JSONEncoder().encode(action), model: model)
        }
        #expect(model.categories.first?.items.first?.selected == true)
        await model.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await CleanerUICommands.execute(
                "cleaner.ui.snapshot", payload: Data("{}".utf8), model: model)
        }
    }
}
