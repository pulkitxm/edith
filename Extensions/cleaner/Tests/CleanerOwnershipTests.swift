import Foundation
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized) struct CleanerOwnershipTests {
    @Test func disablingRejectsLateScanResultsAndProgress() async throws {
        let preferences = try CleanerPreferencesFixture()
        let gate = CleanerRequestGate()
        let model = CleanerModel(
            defaults: preferences.defaults,
            services: CleanerServices(
                drives: { [] },
                scan: { _, cancellation, progress in
                    await gate.wait(cancellation)
                    progress("Late synthetic cache")
                    return Self.result()
                }))
        model.scan()
        await gate.started()
        let shutdown = Task { await model.shutdown() }
        await gate.waitForCancellation()
        await gate.release()
        await shutdown.value
        await Task.yield()
        #expect(model.categories.isEmpty)
        #expect(model.logs.isEmpty)
        #expect(!model.scanning)
        model.scan()
        model.loadDriveOptions()
        model.addCustomFolder("/synthetic/disabled")
        model.toggleDrive("/synthetic/disabled")
        #expect(model.customFolders.isEmpty)
        #expect(preferences.defaults.object(forKey: "cleaner.selectedDrives") == nil)
        #expect(await gate.calls == 1)
    }

    @Test func cancellationRejectsResultsAndAllowsACompleteRetry() async throws {
        let preferences = try CleanerPreferencesFixture()
        let gate = CleanerRequestGate()
        let model = CleanerModel(
            defaults: preferences.defaults,
            services: CleanerServices(
                drives: { [] },
                scan: { _, _, _ in
                    await gate.wait(); return Self.result()
                }))
        defer { model.cancelScan() }
        model.scan()
        await gate.started()
        model.cancelScan()
        await gate.release()
        await model.finishWork()
        #expect(model.categories.isEmpty)
        #expect(!model.scanned)
        #expect(!model.scanning)
        model.scan()
        await model.finishWork()
        #expect(model.categories.map(\.id) == ["synthetic"])
        #expect(model.scanned)
        await model.shutdown()
    }

    @Test func cancellingDuringDriveDiscoveryNeverStartsAScan() async throws {
        let preferences = try CleanerPreferencesFixture()
        let gate = CleanerRequestGate()
        let model = CleanerModel(
            defaults: preferences.defaults,
            services: CleanerServices(
                drives: {
                    await gate.wait(); return []
                },
                scan: { _, _, _ in
                    Issue.record("A cancelled discovery must not start scanning.");
                    return Self.result()
                }))
        model.scan()
        await gate.started()
        model.cancelScan()
        await gate.release()
        await model.finishWork()
        #expect(!model.scanning)
        #expect(model.categories.isEmpty)
        await model.shutdown()
    }

    @Test func disablingCancelsOwnedCleaningAndRejectsItsLateResult() async throws {
        let preferences = try CleanerPreferencesFixture()
        let gate = CleanerRequestGate()
        let model = CleanerModel(
            defaults: preferences.defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in Self.result() },
                clean: { items, cancellation in
                    await gate.wait(cancellation)
                    #expect(cancellation.isCancelled)
                    return CleanerCleanResult(
                        items: items.count, requestedBytes: 32, reclaimedBytes: 32)
                }))
        model.scan()
        await model.finishWork()
        model.clean()
        await gate.started()
        let shutdown = Task { await model.shutdown() }
        await gate.waitForCancellation()
        await gate.release()
        await shutdown.value
        #expect(model.categories.isEmpty)
        #expect(!model.scanning)
        #expect(model.lastReclaimed == 0)
        #expect(await gate.calls == 1)
    }

    @Test func selectionInvalidatesPreviewAndPersistsInItsOwnPreferences() async throws {
        let preferences = try CleanerPreferencesFixture()
        let services = CleanerServices(drives: { [] }, scan: { _, _, _ in Self.result() })
        let model = CleanerModel(defaults: preferences.defaults, services: services)
        model.scan()
        await model.finishWork()
        let preview = model.previewToken
        #expect(model.selectedItemCount == 1)
        model.toggleItem(categoryID: "synthetic", itemID: "selected")
        #expect(model.previewToken != preview)
        #expect(model.selectedItemCount == 0)
        await model.shutdown()
        let restored = CleanerModel(defaults: preferences.defaults, services: services)
        restored.scan()
        await restored.finishWork()
        #expect(restored.selectedItemCount == 0)
        #expect(restored.totalItemCount == 2)
        await restored.shutdown()
        let other = try CleanerPreferencesFixture()
        let isolated = CleanerModel(defaults: other.defaults, services: services)
        isolated.scan()
        await isolated.finishWork()
        #expect(isolated.selectedItemCount == 1)
        await isolated.shutdown()
    }

    @Test func cleanPassesOnlySelectedItemsToItsOwnedService() async throws {
        let preferences = try CleanerPreferencesFixture()
        let received = CleanerItemsProbe()
        let model = CleanerModel(
            defaults: preferences.defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in Self.result() },
                clean: { items, _ in
                    await received.record(items)
                    return CleanerCleanResult(
                        items: items.count, requestedBytes: 32, reclaimedBytes: 32)
                }))
        model.scan()
        await model.finishWork()
        model.clean()
        await model.finishWork()
        #expect(await received.ids == ["selected"])
        #expect(model.lastReclaimed == 32)
        await model.shutdown()
    }

    @Test func cancelledTrashOperationLeavesSyntheticFilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.bin")
        try Data(repeating: 0, count: 32).write(to: file)
        let item = JunkItem(
            id: "synthetic", name: "synthetic.bin", path: file, sizeBytes: 32, selected: true)
        #expect(JunkScanner.clean([item], isCancelled: { true }) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    nonisolated private static func result() -> CleanerScanResult {
        CleanerScanResult(categories: [
            JunkCategory(
                id: "synthetic", name: "Synthetic cache", detail: "Fixture cache files",
                items: [
                    JunkItem(
                        id: "selected", name: "Selected cache",
                        path: URL(fileURLWithPath: "/synthetic/selected"), sizeBytes: 32,
                        selected: true),
                    JunkItem(
                        id: "unselected", name: "Unselected cache",
                        path: URL(fileURLWithPath: "/synthetic/unselected"), sizeBytes: 64,
                        selected: false),
                ])
        ])
    }
}

private final class CleanerPreferencesFixture {
    let suite = "com.pulkit.edith.tests.cleaner.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
    deinit { defaults.removePersistentDomain(forName: suite) }
}

private actor CleanerRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    private var cancellation: CleanerCancellation?
    private let signal = AsyncStream<Void>.makeStream()
    private(set) var calls = 0
    func wait(_ cancellation: CleanerCancellation? = nil) async {
        self.cancellation = cancellation
        calls += 1
        guard !open else { return }
        await withCheckedContinuation {
            continuation = $0
            signal.continuation.yield(())
        }
    }
    func started() async {
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func waitForCancellation() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while cancellation?.isCancelled != true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(cancellation?.isCancelled == true)
    }

    func release() { open = true; continuation?.resume(); continuation = nil }
}

private actor CleanerItemsProbe {
    private(set) var ids: [String] = []
    func record(_ items: [JunkItem]) { ids = items.map(\.id) }
}
