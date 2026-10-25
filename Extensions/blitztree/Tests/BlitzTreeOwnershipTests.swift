import EdithExtensionSupport
import Foundation
import Testing

@testable import BlitzTreeExtension

private actor BlitzTreeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private final class BlitzTreeProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: BlitzTreeClient.Progress?
    func set(_ callback: @escaping BlitzTreeClient.Progress) {
        lock.withLock { self.callback = callback }
    }
    func send(_ count: UInt64) { lock.withLock { callback }?(count) }
}

@MainActor
@Suite struct BlitzTreeOwnershipTests {
    @Test func disablingWaitsForOwnedScanAndRejectsLateProgress() async throws {
        let gate = BlitzTreeGate()
        let progress = BlitzTreeProgressCapture()
        let model = BlitzTreeModel(
            client: BlitzTreeClient { root, callback in
                progress.set(callback)
                await gate.wait()
                return BlitzTreeClientTests.report(root: root)
            })
        model.scan("/synthetic-root")
        #expect(await wait { await gate.waiting })
        let stopping = Task { await model.shutdown() }
        #expect(await wait { model.stopped })
        #expect(model.ownedOperationCount == 1)
        progress.send(999)
        await gate.open()
        await stopping.value
        progress.send(1000)
        await Task.yield()
        #expect(model.scannedEntries == 0)
        #expect(model.report == nil)
        #expect(model.root == nil)
        #expect(model.history.isEmpty)
        #expect(model.ownedOperationCount == 0)
        model.scan("/another-root")
        #expect(model.ownedOperationCount == 0)
    }

    @Test func disablingCancelsTheOwnedTrashServiceAndClearsItsResult() async throws {
        let gate = BlitzTreeGate()
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data([1, 2, 3]).write(to: file)
        let model = BlitzTreeModel(remove: { _, _, cancellation in
            await gate.wait()
            #expect(cancellation.isCancelled)
            throw CancellationError()
        })
        model.scan(root.path)
        await model.finishWork()
        let entry = try #require(model.report?.report.inventory.largestChildren.first)
        model.trash(entry)
        #expect(await wait { await gate.waiting })
        let stopping = Task { await model.shutdown() }
        #expect(await wait { model.stopped })
        await gate.open()
        await stopping.value
        #expect(model.ownedOperationCount == 0)
        #expect(!model.removing)
        #expect(model.error == nil)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    }

    @Test func cancelledTrashNeverMovesSyntheticFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data([1]).write(to: file)
        let report = try BlitzTreeScanner.scan(root: root.path)
        let entry = try #require(report.report.inventory.largestChildren.first)
        #expect(throws: CancellationError.self) {
            try BlitzTreeActions.trash(entry, root: report.root, isCancelled: { true }) { _ in
                Issue.record("Cancellation must prevent moving the item.")
            }
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func trashCommandRequiresTypedConfirmationAndTheCurrentPreview() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data([1]).write(to: file)
        let model = BlitzTreeModel(remove: { _, _, _ in
            Issue.record("Rejected commands cannot remove files.")
        })
        model.scan(root.path)
        await model.finishWork()
        let entry = try #require(model.report?.report.inventory.largestChildren.first)
        for input: [String: Any] in [
            [
                "confirmed": false, "previewToken": model.previewToken.uuidString,
                "path": entry.path,
            ],
            ["confirmed": true, "previewToken": UUID().uuidString, "path": entry.path],
            ["confirmed": 1, "previewToken": model.previewToken.uuidString, "path": entry.path],
            [
                "confirmed": true, "previewToken": model.previewToken.uuidString,
                "path": "/outside-scan",
            ],
        ] {
            do {
                _ = try await BlitzTreeCommands.execute(
                    "blitztree.trash", payload: JSONSerialization.data(withJSONObject: input),
                    model: model)
                Issue.record("Expected preview rejection.")
            } catch is ExtensionPeerError {}
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        await model.shutdown()
    }

    @Test func nativeScanCommandReturnsBoundedCodableResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: 4096).write(to: root.appendingPathComponent("sample.bin"))
        let model = BlitzTreeModel()
        let data = try await BlitzTreeCommands.execute(
            "blitztree.scan", payload: JSONSerialization.data(withJSONObject: ["path": root.path]),
            model: model)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let report = try #require(object["report"] as? [String: Any])
        let expectedRoot = try BlitzTreeScanner.resolvedDirectory(root.path)
        #expect(report["root"] as? String == expectedRoot)
        #expect(object["working"] as? Bool == false)
        #expect(data.count < ExtensionPeerEndpoint.maximumPayloadBytes)
        await model.shutdown()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "blitztree-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wait(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
