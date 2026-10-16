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
        late.maxItems = 7
        continuation?.resume(returning: try ClipboardMessage.encode(late))
        await refresh.value
        #expect(presentation.preferences.maxItems != 7)
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

    @Test func closingClearsHistoryAndCoalescesPreferenceEdits() async throws {
        var saved: [[String: Any]] = []
        let presentation = ClipboardPresentation(send: { operation, payload in
            guard operation == "clipboard.ui.preferences.patch" else {
                throw ExtensionPeerError.invalidRequest
            }
            saved.append(
                try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any]))
            return try ClipboardMessage.encode(ClipboardPreferences())
        })
        for count in 1...20 { presentation.preferences.maxItems = count; presentation.save() }
        for _ in 0..<100 where saved.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(saved.map { $0["maxItems"] as? Int } == [20])
        presentation.preferences.maxItems = 21
        presentation.save()
        presentation.stop()
        try await Task.sleep(for: .milliseconds(180))
        #expect(saved.map { $0["maxItems"] as? Int } == [20])
        #expect(presentation.history.entries.isEmpty)
        #expect(presentation.history.copiedID == nil)
    }

    @Test func engineRecordActionsAndCLIUseInjectedCopySinkAndRejectSystemActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "clipboard-record-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let service = ClipboardService(archive: .init(root: root), defaults: defaults, changed: {})
        var copied: [ClipboardCopyPayload] = []
        let worker = ClipboardWorker(
            service: service, defaults: defaults, capturesPasteboard: false,
            allowsSystemActions: false, copyRecord: { copied.append($0) })
        var preferences = ClipboardPreferences.read(defaults)
        preferences.maxItems = 37
        preferences.ignoredApps = "example.private"
        let savedPreferences = try ClipboardMessage.decode(
            ClipboardPreferences.self,
            from: await worker.execute(
                "clipboard.ui.preferences.set", payload: ClipboardMessage.encode(preferences)))
        #expect(savedPreferences.maxItems == 37)
        #expect(savedPreferences.ignoredApps == "example.private")
        #expect(defaults.integer(forKey: AppStorageKeys.Clipboard.maxItems) == 37)
        let clip = ClipboardCapture(
            payload: .init(
                data: Data("mock owned record".utf8), types: ["public.text"], ext: "txt",
                preview: "mock owned record"), sourceApp: "Mock Editor",
            sourceBundleID: "example.mock")
        _ = try await worker.client.capture(clip)
        _ = try await worker.execute("clipboard.ui.copy", payload: ClipboardMessage.encode(clip.id))
        #expect(copied.first?.text == "mock owned record")
        let reply = try ClipboardMessage.decode(
            ExtensionCLIReply.self,
            from: await worker.execute(
                "cli.execute",
                payload: ClipboardMessage.encode(ExtensionCLIRequest(arguments: ["copy", "1"]))))
        #expect(reply.stdout == "copied entry 1\n")
        #expect(copied.count == 2)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("clipboard.ui.palette", payload: Data("{}".utf8))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("clipboard.ui.permission", payload: Data("{}".utf8))
        }
        await worker.shutdown()
    }

    @Test func runtimeRejectsUncheckedConfigurationAndUnconfiguredView() {
        let runtime = ExtensionRuntime()
        let result =
            runtime.execute(["operation": "configureUI", "remoteUI": true] as NSDictionary)
            as? NSDictionary
        #expect(result?["ok"] as? Bool == false)
        let view = runtime.execute(["operation": "view"] as NSDictionary) as? NSDictionary
        #expect(view?["ok"] as? Bool == false)
        #expect(runtime.responds(to: NSSelectorFromString("invoke:completion:")))
        #expect(runtime.responds(to: NSSelectorFromString("prepareToStopWithCompletion:")))
    }

    @Test func retentionAndPrivacyPreferencesAreClampedBeforeWriting() throws {
        let suite = "clipboard-preferences-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ClipboardPreferences()
        preferences.maxAgeDays = 30
        preferences.ignoredApps = "example.passwords"
        preferences.saveImages = false
        preferences.popupAt = "lastPosition"
        preferences.hotKeyLabel = "⌥⇧V"
        preferences.hotKeyCode = 9
        preferences.hotKeyMods = 2560
        try preferences.save(defaults)
        #expect(ClipboardPreferences.read(defaults) == preferences)
        preferences.checkInterval = .nan
        preferences.maxAgeDays = 45
        try preferences.save(defaults)
        let clamped = ClipboardPreferences.read(defaults)
        #expect(clamped.checkInterval == ClipboardIndex.defaultCheckInterval)
        #expect(clamped.maxAgeDays == 30)
    }

    @Test func patchesCarryOnlyChangedKeysAndKeepConcurrentValues() throws {
        let suite = "clipboard-patch-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = ClipboardPreferences.read(defaults)
        var edited = base
        edited.maxItems = 55
        var concurrent = base
        concurrent.capturePaused = true
        try concurrent.save(defaults)
        let patch = try edited.changes(from: base)
        let keys = try #require(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        #expect(Set(keys.keys) == ["maxItems"])
        try ClipboardPreferences.patched(defaults, with: patch).save(defaults)
        let merged = ClipboardPreferences.read(defaults)
        #expect(merged.maxItems == 55)
        #expect(merged.capturePaused)
        #expect(throws: ExtensionPeerError.self) {
            try ClipboardPreferences.patched(defaults, with: Data(#"{"unknown":1}"#.utf8))
        }
    }
}
