import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EDITH_BACKUP_RUNTIME_FIXTURE"] == "1"))
@MainActor struct ClipboardBackupRuntimeTests {
    @Test func actualRuntimeRestoresSchedulesAndDrainsAcrossReplacement() async throws {
        let environment = ProcessInfo.processInfo.environment
        let identifier = try #require(environment["EDITH_APPLICATION_IDENTIFIER"])
        let suite = try #require(environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let path = try #require(environment["EDITH_EXTENSION_DATA_ROOT"])
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let fixture = URL(
            fileURLWithPath: try #require(environment["EDITH_EXTENSION_FIXTURE_HOME"]))
        try #require(identifier.hasPrefix("com.pulkit.edith.tests."))
        try #require(identifier == suite)
        try #require(root.lastPathComponent == "clipboard")
        try #require(root.deletingLastPathComponent().lastPathComponent == "Data")
        try #require(root.deletingLastPathComponent().deletingLastPathComponent() == fixture)
        try #require(fixture.path.hasPrefix("/tmp/") || fixture.path.hasPrefix("/private/tmp/"))
        let defaults = try #require(SharedDefaults.applicationStore(identifier: identifier))
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
        let cloud = try ClipboardBackupProvider.cloudDirectory(identifier: identifier, root: root)
        let local = ClipboardArchive(root: root.appendingPathComponent("clipboard"))
        let seed = ClipboardArchive(root: root.appendingPathComponent("seed"))
        let remote = try capture("restored", in: seed)
        try seed.stageExport(to: cloud)
        let selected = try capture("selected", in: local)
        _ = NSApplication.shared
        let first = ExtensionRuntime()
        var replacement: ExtensionRuntime?
        do {
            #expect(
                (first.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                    == false)
            try start(first, suite: suite)
            await wait { (try? local.snapshot(.init()).total) == 2 }
            #expect(try local.payload(id: remote.id).data == remote.data)
            #expect(try local.payload(id: selected.id).data == selected.data)
            await wait { (try? ClipboardArchive(root: cloud).snapshot(.init()).total) == 2 }
            let scheduled = try await waitForIdle(first)
            #expect(scheduled["running"] as? Bool == false)
            #expect(scheduled["scheduled"] as? Bool == false)
            await stop(first)
            let later = try capture("after disable", in: local)
            IPC.post(IPC.Name.clipboardChanged)
            IPC.post(IPC.Name.settingsChanged)
            try await Task.sleep(for: .milliseconds(100))
            #expect(try ClipboardArchive(root: cloud).snapshot(.init()).total == 2)
            await #expect(throws: ExtensionPeerError.self) {
                try await invoke(first, command: "backup.status")
            }
            let next = ExtensionRuntime()
            replacement = next
            try start(next, suite: suite)
            await wait { (try? ClipboardArchive(root: cloud).snapshot(.init()).total) == 3 }
            #expect(try ClipboardArchive(root: cloud).payload(id: later.id).data == later.data)
            defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
            IPC.post(IPC.Name.settingsChanged)
            _ = try capture("opted out", in: local)
            IPC.post(IPC.Name.clipboardChanged)
            let disabled = try await waitForIdle(next)
            #expect(disabled["scheduled"] as? Bool == false)
            #expect(disabled["running"] as? Bool == false)
            await stop(next)
            #expect(try ClipboardArchive(root: cloud).snapshot(.init()).total == 3)
            #expect(try local.snapshot(.init()).total == 4)
        } catch {
            await stop(first)
            if let replacement { await stop(replacement) }
            throw error
        }
    }

    private func start(_ runtime: ExtensionRuntime, suite: String) throws {
        let result = runtime.execute(["operation": "start", "defaultsSuite": suite])
        try #require((result as? NSDictionary)?["ok"] as? Bool == true)
    }

    private func stop(_ runtime: ExtensionRuntime) async {
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        _ = runtime.execute(["operation": "stop"])
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
    }

    private func invoke(_ runtime: ExtensionRuntime, command: String) async throws -> [String: Any]
    {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(["token": UUID().uuidString, "command": command, "payload": Data()]) {
                data, error in
                if let error {
                    continuation.resume(throwing: ExtensionPeerError.rejected(error as String))
                } else if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(throwing: ExtensionPeerError.unavailable)
                }
            }
        }
        return try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    private func capture(_ value: String, in archive: ClipboardArchive) throws -> ClipboardCapture {
        let value = ClipboardCapture(
            payload: .init(
                data: Data(value.utf8), types: ["public.utf8-plain-text"], ext: "txt",
                preview: value),
            sourceApp: nil, sourceBundleID: nil)
        _ = try archive.capture(value, maxItems: 200, maxBytes: 1000, maxAge: nil)
        return value
    }

    private func waitForIdle(_ runtime: ExtensionRuntime) async throws -> [String: Any] {
        var status = try await invoke(runtime, command: "backup.status")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (status["scheduled"] as? Bool != false || status["running"] as? Bool != false),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
            status = try await invoke(runtime, command: "backup.status")
        }
        return status
    }

    private func wait(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready())
    }
}
