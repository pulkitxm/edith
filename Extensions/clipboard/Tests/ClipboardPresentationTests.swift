import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardPresentationTests {
    @Test func readonlyFacadeUsesFixedRecordsAndCancelsLateRefresh() async throws {
        var operations: [String] = []
        var invalidated = false
        var continuation: CheckedContinuation<Data, Error>?
        let presentation = ClipboardPresentation(
            send: { operation, _ in
                operations.append(operation)
                if operation == "clipboard.ui.preferences" {
                    return try await withCheckedThrowingContinuation { continuation = $0 }
                }
                throw ExtensionPeerError.invalidRequest
            }, invalidate: { invalidated = true })
        let refresh = Task { await presentation.refresh() }
        while continuation == nil { await Task.yield() }
        presentation.stop()
        var late = ClipboardPreferences()
        late.enabled = true
        continuation?.resume(returning: try ClipboardMessage.encode(late))
        await refresh.value
        #expect(!presentation.preferences.enabled)
        #expect(presentation.error == nil)
        #expect(invalidated)
        #expect(presentation.stopped)
        presentation.save()
        presentation.action("filesystem.open")
        #expect(operations == ["clipboard.ui.preferences"])
        await #expect(throws: ExtensionPeerError.self) {
            try await presentation.client.capture(
                .init(
                    payload: .init(data: Data(), types: [], ext: "txt", preview: "mock"),
                    sourceApp: nil, sourceBundleID: nil))
        }
    }

    @Test func ownedSnapshotPreservesHistorySearchAndPinActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "clipboard-presentation-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let service = ClipboardService(archive: .init(root: root), defaults: defaults, changed: {})
        let client = ClipboardClient(service: service)
        let clip = ClipboardCapture(
            payload: .init(
                data: Data("synthetic note".utf8), types: ["public.text"], ext: "txt",
                preview: "synthetic note"), sourceApp: "Mock Notes", sourceBundleID: "example.notes"
        )
        _ = try await client.capture(clip)
        var copied: [String] = []
        let presentation = ClipboardPresentation(send: { operation, payload in
            if operation == "clipboard.ui.copy" {
                copied.append(try ClipboardMessage.decode(String.self, from: payload));
                return Data("{}".utf8)
            }
            return try await service.perform(
                operation: operation.replacingOccurrences(of: "clipboard.ui.", with: "clipboard."),
                payload: payload)
        })
        presentation.history.start()
        for _ in 0..<100 where presentation.history.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let entry = try #require(presentation.history.entries.first)
        #expect(
            ClipboardActions.arrange(presentation.history.entries, query: "mock synthetic").count
                == 1)
        presentation.history.mutate(.init(.pin, ids: [entry.id]))
        for _ in 0..<100 where presentation.history.isSaving {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await client.entries().first?.pinned == true)
        presentation.history.copy(entry)
        for _ in 0..<100 where presentation.history.isSaving {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(copied == [entry.id])
        #expect(presentation.history.copiedID == entry.id)
        presentation.stop()
        await service.stop()
    }

    @Test func retentionAndPrivacyPreferencesAreValidatedBeforeWriting() throws {
        let suite = "clipboard-preferences-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ClipboardPreferences()
        preferences.maxAgeDays = 30
        preferences.ignoredApps = "example.passwords"
        preferences.saveImages = false
        preferences.popupAt = "lastPosition"
        try preferences.save(defaults)
        #expect(ClipboardPreferences.read(defaults) == preferences)
        preferences.checkInterval = .nan
        #expect(throws: ExtensionPeerError.self) { try preferences.save(defaults) }
        #expect(ClipboardPreferences.read(defaults).checkInterval.isFinite)
    }
}
