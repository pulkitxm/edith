import EdithExtensionSupport
import Foundation
import Testing
@testable import BifrostExtension

@Suite(.serialized) @MainActor struct BifrostOriginalCLITests {
    @Test func originalCalculatorConversionAndErrorsPreserveOutput() async throws {
        let suite = "bifrost.cli.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let store = BifrostStore(
            store: defaults, indexStore: .init(location: root.appendingPathComponent("index.json")),
            startServices: false, scan: { [] }, open: { _ in false }, copy: { _ in })
        defer { store.shutdown() }
        let calculated = try await BifrostCLIExecution.run(
            .init(arguments: ["calc", "12 * 8", "--json"]), store: store)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(calculated.stdout.utf8)) as? [String: Any])
        #expect(calculated.exitCode == 0 && object["value"] as? Double == 96)
        let converted = try await BifrostCLIExecution.run(
            .init(arguments: ["convert", "12 km in miles", "--json"]), store: store)
        let conversion = try #require(
            JSONSerialization.jsonObject(with: Data(converted.stdout.utf8)) as? [String: Any])
        #expect(converted.exitCode == 0 && conversion["to"] as? String == "mile")
        let result = try #require(conversion["result"] as? Double)
        #expect(abs(result - 7.456454307) < 0.000000001)
        let invalid = try await BifrostCLIExecution.run(
            .init(arguments: ["calc", "invalid expression"]), store: store)
        #expect(invalid.exitCode != 0 && invalid.stderr.contains("not an expression"))
        let help = try await BifrostCLIExecution.run(.init(arguments: ["--help"]), store: store)
        #expect(
            help.exitCode == 0 && help.stdout.contains("reindex") && help.stdout.contains("clear"))
    }

    @Test func checkedPreferencesRejectInvalidAndLateResponses() async throws {
        let key = AppStorageKeys.Bifrost.resultLimit
        #expect(throws: ExtensionPeerError.self) { try BifrostUIContext.set(key, value: "0") }
        #expect(throws: ExtensionPeerError.self) {
            try BifrostUIContext.set("host.private", value: "true")
        }
        let context = BifrostUIContext(invoke: { _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return try JSONEncoder().encode(BifrostUISettings(values: [key: "8"], index: nil))
        })
        let loading = Task { await context.load() }
        await Task.yield(); context.shutdown(); await loading.value
        #expect(!context.loaded && context.index == nil)
    }
}
