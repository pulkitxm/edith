import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardCLITests {
    @Test func originalCommandsUseOwnedHistoryAndPreserveOutputAndPlans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "clipboard-cli-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "clipboardEnabled")
        let service = ClipboardService(archive: .init(root: root), defaults: defaults, changed: {})
        let client = ClipboardClient(service: service)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let capture = ClipboardCapture(
            payload: .init(
                data: Data("mock text\nsecond line".utf8),
                types: ["public.text"], ext: "txt", preview: "mock text"),
            sourceApp: "Mock Editor", sourceBundleID: "example.mock")
        _ = try await client.capture(capture)
        var copied: [ClipboardCopyPayload] = []
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await ClipboardCLIExecution.run(
                .init(arguments: arguments), client: client,
                defaults: defaults, copy: { copied.append($0) })
        }
        let listed = try await run(["ls", "--search", "Mock Editor", "--json"])
        #expect(listed.exitCode == 0)
        #expect(listed.stderr.isEmpty)
        #expect(listed.stdout.contains(capture.id))
        let text = try await run(["get", "1"])
        #expect(text.stdout == "mock text\nsecond line\n")
        #expect(text.exitCode == 0)
        let copy = try await run(["copy", "1", "--plain"])
        #expect(copy.stdout == "copied entry 1\n")
        #expect(copied.first?.text == "mock text\nsecond line")
        let pin = try await run(["pin", "1", "--json"])
        #expect(pin.exitCode == 0)
        #expect(try await client.entries().first?.pinned == true)
        let kept = try await run(["clear", "--yes", "--keep-pinned", "--json"])
        #expect(kept.exitCode == 0)
        #expect(try await client.entries().count == 1)
        let preview = try await run(["rm", "1", "--json"])
        #expect(
            (try JSONSerialization.jsonObject(with: Data(preview.stdout.utf8)) as? [String: Any])?[
                "applied"] as? Bool == false)
        #expect(try await client.entries().count == 1)
        let unpin = try await run(["unpin", "1"])
        #expect(unpin.stdout == "unpinned entry 1\n")
        let stats = try await run(["stats", "--json"])
        #expect(stats.exitCode == 0)
        #expect(
            (try JSONSerialization.jsonObject(with: Data(stats.stdout.utf8)) as? [String: Any])?[
                "count"] as? Int == 1)
        let missing = try await run(["get", "2"])
        #expect(missing.exitCode == 3)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr.contains("there is no clipboard entry 2"))
        let invalid = try await run(["ls", "--limit", "-1"])
        #expect(invalid.exitCode == 2)
        let removed = try await run(["rm", "1", "--yes"])
        #expect(removed.stdout == "removed entry 1, 0 left\n")
        let empty = try await run(["get", "1"])
        #expect(empty.exitCode == 4)
        await service.stop()
    }
}
