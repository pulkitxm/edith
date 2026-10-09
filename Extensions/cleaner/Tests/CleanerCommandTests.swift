import EdithExtensionSupport
import Foundation
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized) struct CleanerCommandTests {
    @Test func cleaningRequiresConfirmationAndTheCurrentPreview() async throws {
        let suite = "com.pulkit.edith.tests.cleaner-command.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = CleanerCommandProbe()
        let model = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in Self.result() },
                clean: { items, _ in
                    await probe.cleaned(items)
                    return CleanerCleanResult(
                        items: items.count, requestedBytes: 32, reclaimedBytes: 32)
                }))
        let blankPreview = model.previewToken.uuidString
        await #expect(throws: ExtensionPeerError.self) {
            try await CleanerCommands.execute(
                "cleaner.clean", payload: Self.input(true, token: blankPreview), model: model)
        }
        _ = try await CleanerCommands.execute("cleaner.scan", payload: Data(), model: model)
        let oldPreview = model.previewToken.uuidString
        model.toggleAll()
        model.toggleAll()
        for (confirmed, token) in [(false, model.previewToken.uuidString), (true, oldPreview)] {
            await #expect(throws: ExtensionPeerError.self) {
                try await CleanerCommands.execute(
                    "cleaner.clean", payload: Self.input(confirmed, token: token), model: model)
            }
        }
        let malformed = try JSONSerialization.data(withJSONObject: [
            "confirmed": 1, "previewToken": model.previewToken.uuidString,
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await CleanerCommands.execute("cleaner.clean", payload: malformed, model: model)
        }
        #expect(await probe.calls == 0)
        _ = try await CleanerCommands.execute(
            "cleaner.clean", payload: Self.input(true, token: model.previewToken.uuidString),
            model: model)
        #expect(await probe.calls == 1)
        #expect(await probe.ids == ["synthetic"])
        #expect(model.lastReclaimed == 32)
        await model.shutdown()
    }

    @Test func operationDescriptorsSeparatePreviewFromDestructiveExecution() {
        #expect(CleanerOperation.scan.descriptor.effect == .read)
        #expect(!CleanerOperation.scan.descriptor.requiresPreview)
        #expect(CleanerOperation.clean.descriptor.effect == .destructive)
        #expect(CleanerOperation.clean.descriptor.requiresPreview)
        #expect(CleanerOperation.clean.descriptor.cli == ["cleaner", "clean"])
    }

    nonisolated private static func input(_ confirmed: Bool, token: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["confirmed": confirmed, "previewToken": token])
    }

    nonisolated private static func result() -> CleanerScanResult {
        CleanerScanResult(categories: [
            JunkCategory(
                id: "synthetic", name: "Synthetic cache", detail: "Fixture cache",
                items: [
                    JunkItem(
                        id: "synthetic", name: "Synthetic cache",
                        path: URL(fileURLWithPath: "/synthetic/cache"), sizeBytes: 32,
                        selected: true)
                ])
        ])
    }
}

private actor CleanerCommandProbe {
    private(set) var calls = 0
    private(set) var ids: [String] = []
    func cleaned(_ items: [JunkItem]) { calls += 1; ids = items.map(\.id) }
}
