import EdithExtensionSupport
import Foundation
import Testing

@testable import AppMaintenanceExtension

private final class MaintenanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var opened = false
    var hasStarted: Bool { lock.withLock { started } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                started = true
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

@MainActor
@Suite struct MaintenanceOwnershipTests {
    @Test func disablingWaitsForOwnedDiscoveryAndRejectsLateResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MaintenanceGate()
        let app = application()
        let model = model(
            root: root,
            inventory: { _ in
                await gate.wait()
                return [app]
            })
        model.refresh()
        #expect(await wait { gate.hasStarted })
        let stopping = Task { await model.shutdown() }
        #expect(await wait { model.stopped })
        #expect(model.ownedOperationCount == 1)
        model.refresh()
        model.select(app)
        gate.open()
        await stopping.value
        #expect(model.ownedOperationCount == 0)
        #expect(model.applications.isEmpty)
        #expect(model.updates.isEmpty)
        #expect(model.plan == nil)
        #expect(!model.checkingUpdates)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("snapshot.json").path))
    }

    @Test func cancelledDiscoveryCannotWriteItsLateSnapshot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MaintenanceGate()
        let app = application()
        let model = AppMaintenanceModel(
            persistence: AppUpdatePersistence(fileURL: root.appendingPathComponent("state.json")),
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: root.appendingPathComponent("snapshot.json")),
            inventory: { _ in [app] },
            discover: { _, _, _, onBatch in
                await gate.wait()
                await onBatch(AppUpdateDiscoveryBatch(channel: .appStore, items: []))
                return []
            })
        model.refresh()
        #expect(await wait { gate.hasStarted })
        model.cancel()
        gate.open()
        await model.finishWork()
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("snapshot.json").path))
        await model.shutdown()
        #expect(model.ownedOperationCount == 0)
    }

    @Test func destructiveCommandsRequireCurrentTypedConfirmation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        model.phase = .ready
        let oldPreview = model.previewToken
        model.selectedItemIDs = ["synthetic-selection"]
        #expect(model.previewToken != oldPreview)
        for command in ["maintenance.remove", "maintenance.update", "maintenance.install"] {
            for input: [String: Any] in [
                [
                    "confirmed": false, "previewToken": model.previewToken.uuidString,
                    "concurrency": 2, "retries": 1, "replaceExisting": false,
                    "moveImageToTrash": false,
                ],
                [
                    "confirmed": true, "previewToken": oldPreview.uuidString, "concurrency": 2,
                    "retries": 1, "replaceExisting": false, "moveImageToTrash": false,
                ],
                [
                    "confirmed": 1, "previewToken": model.previewToken.uuidString, "concurrency": 2,
                    "retries": 1, "replaceExisting": false, "moveImageToTrash": false,
                ],
            ] {
                do {
                    _ = try await MaintenanceCommands.execute(
                        command, payload: JSONSerialization.data(withJSONObject: input),
                        model: model)
                    Issue.record("Expected rejection before any operation.")
                } catch is ExtensionPeerError {}
            }
        }
        #expect(model.ownedOperationCount == 0)
        await model.shutdown()
    }

    @Test func stoppedModelRejectsCommandsAndNewOperations() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        await model.shutdown()
        model.refresh()
        model.removeSelected()
        model.runSelectedUpdates(concurrency: 2, retries: 1)
        model.prepareDiskImage(root.appendingPathComponent("Mock.dmg"), destination: .user)
        do {
            _ = try await MaintenanceCommands.execute(
                "maintenance.refresh", payload: Data(), model: model)
            Issue.record("Expected a disabled extension to reject commands.")
        } catch is ExtensionPeerError {}
        #expect(model.ownedOperationCount == 0)
    }

    @Test func concurrentMutationsCannotReplaceAnOwnedOperation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        model.phase = .installing
        model.refresh()
        model.select(application())
        model.prepareDiskImage(root.appendingPathComponent("Mock.dmg"), destination: .user)
        #expect(model.phase == .installing)
        #expect(model.ownedOperationCount == 0)
        await model.shutdown()
    }

    @Test func backupsPreserveHistoryAndNeverOverwriteAnExistingFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root)
        let backup = root.appendingPathComponent("backup.json")
        let payload = try JSONSerialization.data(withJSONObject: ["path": backup.path])
        let output = try await MaintenanceCommands.execute(
            "maintenance.backup-updates", payload: payload, model: model)
        #expect(String(decoding: output, as: UTF8.self).contains("true"))
        let original = try Data(contentsOf: backup)
        #expect(throws: AppUpdateCenterError.invalidBackupDestination) {
            try model.backupUpdates(to: backup)
        }
        #expect(try Data(contentsOf: backup) == original)
        await model.shutdown()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maintenance-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func model(root: URL, inventory: @escaping AppMaintenanceInventoryLoad = { _ in [] })
        -> AppMaintenanceModel
    {
        AppMaintenanceModel(
            persistence: AppUpdatePersistence(fileURL: root.appendingPathComponent("state.json")),
            snapshots: AppMaintenanceSnapshotStore(
                fileURL: root.appendingPathComponent("snapshot.json")),
            inventory: inventory, discover: { _, _, _, _ in [] })
    }

    private func application() -> InstalledApplication {
        InstalledApplication(
            id: "fixture", name: "Mock Editor", bundleID: "com.example.editor", version: "1",
            url: URL(fileURLWithPath: "/Applications/Mock Editor.app"))
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
