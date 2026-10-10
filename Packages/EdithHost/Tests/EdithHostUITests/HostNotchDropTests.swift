import AppKit
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchDropTests {
    @Test func privateSyntheticPasteboardDelegatesOriginalFilesAndTextWithExactOrigin() async throws
    {
        _ = TestWindowHost.application
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        let board = NSPasteboard(name: .init("notch-fixture-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let url = fixture.temporary.appendingPathComponent("synthetic.txt")
        try Data("synthetic dropped file".utf8).write(to: url)
        board.clearContents()
        #expect(board.writeObjects([url as NSURL]))
        let input = HostNotchDropInput.read(board)
        #expect(input.fileURLs == [url] && input.promises.isEmpty)
        try fixture.accept(input)
        await fixture.settle { fixture.drops.count == 1 }
        #expect(fixture.receivedData == Data("synthetic dropped file".utf8))
        #expect(fixture.drops[0].identity == fixture.identity)
        #expect(
            fixture.drops[0].displayID == 9
                && fixture.drops[0].presentationID == fixture.presentationID)
        #expect(fixture.drops[0].x == 100 && fixture.drops[0].y == 50)
        board.clearContents()
        #expect(board.setString("synthetic shelf note", forType: .string))
        try fixture.accept(.read(board))
        await fixture.settle { fixture.drops.count == 2 }
        #expect(fixture.drops[1].text == "synthetic shelf note")
        try await fixture.proxy.stop()
        #expect(fixture.proxy.pendingCount == 0 && TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func multiplePromisedFilesUseOneNativeDestinationAndActualCopiesBeforeEngineAdoption()
        async throws
    {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        let first = NotchSyntheticPromiseSource(names: ["one.txt", "two.txt"])
        let second = NotchSyntheticPromiseSource(names: ["three.txt"])
        try fixture.accept(.init(fileURLs: [], text: nil, promises: [first, second]))
        await fixture.settle { first.destination != nil && second.destination != nil }
        #expect(first.destination == second.destination)
        first.deliver(); second.deliver()
        await fixture.settle { fixture.proxy.pendingCount == 0 }
        #expect(fixture.adopted.count == 3)
        #expect(
            Set(fixture.adopted.values)
                == Set([Data("one.txt".utf8), Data("two.txt".utf8), Data("three.txt".utf8)]))
        #expect(fixture.prepared.count == 3 && fixture.finished.count == 3)
        #expect(fixture.finished.allSatisfy { $0.fileURL != nil })
        try await fixture.proxy.stop()
    }

    @Test func pendingDisableRetainsIssuedDirectoryUntilOwnedNativeWriterCallbacksDrain()
        async throws
    {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        let source = NotchSyntheticPromiseSource(names: ["late.txt"])
        try fixture.accept(.init(fileURLs: [], text: nil, promises: [source]))
        await fixture.settle { source.destination != nil }
        let destination = try #require(source.destination)
        fixture.admits = false
        await #expect(throws: HostNotchPanelError.staleState) { try await fixture.proxy.stop() }
        #expect(fixture.proxy.pendingCount == 1 && fixture.finished.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        source.deliver()
        await fixture.settle { fixture.proxy.pendingCount == 0 }
        #expect(fixture.finished.count == 1 && fixture.finished[0].fileURL == nil)
        #expect(fixture.adopted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try await fixture.proxy.stop()
    }

    @Test func lostFinishReplyRetriesExactOutcomeAndDoesNotRepeatConfirmedFiles() async throws {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        fixture.failFinish = true
        let source = NotchSyntheticPromiseSource(names: ["one.txt"])
        try fixture.accept(.init(fileURLs: [], text: nil, promises: [source]))
        await fixture.settle { source.destination != nil }
        source.deliver()
        await fixture.settle { fixture.proxy.failure != nil && fixture.finished.count == 1 }
        #expect(fixture.proxy.pendingCount == 1)
        fixture.failFinish = false
        try await fixture.proxy.stop()
        #expect(fixture.finished.count == 2 && fixture.finished[0] == fixture.finished[1])
        #expect(fixture.proxy.pendingCount == 0)
    }

    @Test func failedNativeWriterDrainsAndDiscardsExactIssuedDirectory() async throws {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        let source = NotchSyntheticPromiseSource(names: ["failed.txt"])
        source.failed = true
        try fixture.accept(.init(fileURLs: [], text: nil, promises: [source]))
        await fixture.settle { source.destination != nil }
        source.deliver()
        await fixture.settle { fixture.proxy.pendingCount == 0 }
        #expect(fixture.finished.count == 1 && fixture.finished[0].fileURL == nil)
        #expect(fixture.adopted.isEmpty)
        try await fixture.proxy.stop()
    }

    @Test func cancelledQueuedPromiseDoesNotPrepareOrStartNativeWriter() async throws {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        let source = NotchSyntheticPromiseSource(names: ["never.txt"])
        try fixture.accept(.init(fileURLs: [], text: nil, promises: [source]))
        try await fixture.proxy.stop()
        #expect(fixture.prepared.isEmpty && fixture.finished.isEmpty && source.destination == nil)
    }

    @Test func staleOriginUnboundedTextAndCancellationBeforePrepareDoNotSendNativeWork()
        async throws
    {
        let fixture = NotchDropFixture()
        defer { fixture.cleanup() }
        fixture.admits = false
        #expect(throws: HostNotchPanelError.staleState) {
            try fixture.accept(.init(fileURLs: [], text: "note", promises: []))
        }
        fixture.admits = true
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.accept(
                .init(fileURLs: [], text: String(repeating: "x", count: 65537), promises: []))
        }
        try fixture.accept(.init(fileURLs: [], text: "cancelled note", promises: []))
        fixture.proxy.cancelPending()
        await fixture.settle { fixture.proxy.pendingCount == 0 }
        #expect(fixture.drops.isEmpty)
        try await fixture.proxy.stop()
    }
}

@MainActor
private final class NotchDropFixture {
    let identity = HostNotchPanelIdentity(ownershipID: UUID(), generation: UUID())
    let presentationID = UUID()
    let temporary: URL
    var admits = true
    var drops: [HostNotchPanelDrop] = []
    var receivedData: Data?
    var prepared: [UUID: URL] = [:]
    var finished: [HostNotchPanelPromise] = []
    var adopted: [UUID: Data] = [:]
    var failFinish = false
    var confirmed: [UUID: HostNotchPanelPromise] = [:]
    lazy var proxy = HostNotchDropProxy(
        invoke: invoke,
        admitted: { [self] identity, display, presentation in
            admits && identity == self.identity && display == 9 && presentation == presentationID
        })

    init() {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notch-drop-fixture-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    }
    func cleanup() {
        for directory in prepared.values { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.removeItem(at: temporary)
    }
    func accept(_ input: HostNotchDropInput) throws {
        try proxy.accept(
            input, identity: identity, displayID: 9, presentationID: presentationID,
            point: .init(x: 100, y: 50))
    }
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    func invoke(_ operation: String, payload: Data, timeout: Double) async throws -> Data {
        switch operation {
        case "notch.panel.drop":
            let request = try JSONDecoder().decode(HostNotchPanelDrop.self, from: payload)
            drops.append(request)
            if let url = request.fileURLs.first { receivedData = try Data(contentsOf: url) }
        case "notch.panel.promise.prepare":
            let request = try JSONDecoder().decode(HostNotchPanelPromise.self, from: payload)
            let root = temporary.appendingPathComponent(
                "edith-shelf-incoming-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            prepared[request.id] = root
            return try JSONEncoder().encode(root)
        case "notch.panel.promise.finish":
            let request = try JSONDecoder().decode(HostNotchPanelPromise.self, from: payload)
            finished.append(request)
            if let previous = confirmed[request.id] {
                #expect(previous == request)
                return Data("{}".utf8)
            }
            if let url = request.fileURL { adopted[request.id] = try Data(contentsOf: url) }
            if let root = prepared[request.id] { try FileManager.default.removeItem(at: root) }
            confirmed[request.id] = request
            if failFinish { throw HostWorkerError.rejected }
        default: throw HostWorkerError.rejected
        }
        return Data("{}".utf8)
    }
}

@MainActor
private final class NotchSyntheticPromiseSource: HostNotchPromiseSource {
    let names: [String]
    var failed = false
    var destination: URL?
    var queue: OperationQueue?
    var completion: (@Sendable (URL?, Bool) -> Void)?
    var fileCount: Int { names.count }
    init(names: [String]) { self.names = names }
    func receive(
        at destination: URL, queue: OperationQueue,
        completion: @escaping @Sendable (URL?, Bool) -> Void
    ) -> Int {
        self.destination = destination; self.queue = queue; self.completion = completion
        return names.count
    }
    func deliver() {
        guard let destination, let queue, let completion else { return }
        let failed = failed
        for name in names {
            queue.addOperation {
                if failed { completion(nil, true); return }
                let url = destination.appendingPathComponent(name)
                do { try Data(name.utf8).write(to: url); completion(url, false) } catch {
                    completion(nil, true)
                }
            }
        }
    }
}
