import AppKit
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchTransferTests {
    @Test func issuedSyntheticFilesReachDelegateAndRemainPinnedUntilFinishAcknowledgement()
        async throws
    {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        let proxy = fixture.proxy()
        try fixture.accept(proxy)
        await fixture.settle { fixture.acknowledgements.count == 1 }
        #expect(fixture.received == Data("synthetic shelf document".utf8))
        #expect(proxy.pendingCount == 1 && fixture.finishes.isEmpty)
        fixture.failFinish = true
        fixture.complete(true, true, nil)
        await fixture.settle { fixture.finishes.count == 1 && proxy.failure != nil }
        #expect(proxy.pendingCount == 1)
        #expect(fixture.finishes[0].identity == fixture.identity)
        #expect(fixture.finishes[0].completed && fixture.finishes[0].outside)
        fixture.failFinish = false
        try await proxy.stop()
        #expect(fixture.finishes.count == 2 && fixture.finishes[0] == fixture.finishes[1])
        #expect(proxy.pendingCount == 0)
        #expect(!fixture.panel.isVisible)
    }

    @Test func cancellationWaitsForNativeCompletionBeforeReleasingIssuedSelection() async throws {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        fixture.cancelCloses = false
        let proxy = fixture.proxy()
        try fixture.accept(proxy)
        await fixture.settle { fixture.acknowledgements.count == 1 }
        await #expect(throws: HostNotchPanelError.staleState) { try await proxy.stop() }
        #expect(proxy.pendingCount == 1 && fixture.finishes.isEmpty)
        #expect(fixture.cancelled)
        fixture.complete(true, true, nil)
        await fixture.settle { proxy.pendingCount == 0 }
        #expect(!fixture.finishes[0].completed && !fixture.finishes[0].outside)
        try await proxy.stop()
    }

    @Test func descriptorRejectsWrongPresentationUnissuedPathsAndChangedTransfer() async throws {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        let proxy = fixture.proxy()
        var foreign = fixture.transfer
        foreign = .init(
            id: foreign.id, displayID: foreign.displayID, presentationID: UUID(),
            kind: foreign.kind, items: foreign.items, fileURLs: foreign.fileURLs)
        #expect(throws: HostNotchPanelError.invalidState) {
            try proxy.accept([foreign], identity: fixture.identity, states: [fixture.state]) { _ in
                fixture.panel
            }
        }
        let bad = HostNotchPanelTransfer(
            id: UUID(), displayID: fixture.state.displayID,
            presentationID: fixture.state.presentationID, kind: .share,
            items: fixture.transfer.items,
            fileURLs: [
                fixture.root.deletingLastPathComponent().appendingPathComponent("private.txt")
            ])
        #expect(throws: HostNotchPanelError.invalidState) {
            try bad.validate(states: [fixture.state])
        }
        try fixture.accept(proxy)
        await fixture.settle { fixture.acknowledgements.count == 1 }
        #expect(throws: HostNotchPanelError.staleState) {
            try proxy.accept(
                [
                    .init(
                        id: UUID(), displayID: fixture.state.displayID,
                        presentationID: fixture.state.presentationID, kind: .share,
                        items: fixture.transfer.items,
                        fileURLs: fixture.transfer.fileURLs)
                ], identity: fixture.identity, states: [fixture.state]
            ) { _ in fixture.panel }
        }
        try await proxy.stop()
    }

    @Test func pinsRejectSymlinkAndReplacedFileBeforeNativeDelegation() async throws {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        let pins = try HostNotchIssuedFiles(urls: fixture.transfer.fileURLs)
        let url = fixture.transfer.fileURLs[0]
        try FileManager.default.moveItem(
            at: url, to: fixture.root.appendingPathComponent("original.txt"))
        try Data("replaced".utf8).write(to: url)
        #expect(throws: HostNotchPanelError.staleState) { try pins.validate() }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: fixture.root.appendingPathComponent("original.txt"))
        #expect(throws: HostNotchPanelError.invalidState) { try HostNotchIssuedFiles(urls: [url]) }
    }

    @Test func cancellationBeforeStartNeverDelegatesAndCompletedDescriptorCannotReopen()
        async throws
    {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        let proxy = fixture.proxy()
        try fixture.accept(proxy)
        proxy.cancelPending()
        await fixture.settle { proxy.pendingCount == 0 }
        #expect(fixture.received == nil && fixture.acknowledgements.isEmpty)
        #expect(fixture.finishes.count == 1 && !fixture.finishes[0].completed)
        try fixture.accept(proxy)
        #expect(proxy.pendingCount == 0 && fixture.finishes.count == 1)
        try await proxy.stop()
    }

    @Test func synchronousNativeCompletionStillAcknowledgesActualOpenBeforeFinish() async throws {
        let fixture = try NotchTransferFixture()
        defer { fixture.removeFiles() }
        fixture.finishDuringBegin = true
        let proxy = fixture.proxy()
        try fixture.accept(proxy)
        await fixture.settle { proxy.pendingCount == 0 }
        #expect(fixture.operations == ["notch.panel.transfer.ack", "notch.panel.transfer.finish"])
        #expect(fixture.finishes[0].completed)
        try await proxy.stop()
    }
}

@MainActor
private final class NotchTransferFixture {
    let panel: HostNotchPanel
    let root: URL
    let state: HostNotchPanelState
    let identity: HostNotchPanelIdentity
    let transfer: HostNotchPanelTransfer
    var acknowledgements: [HostNotchTransferAcknowledgement] = []
    var finishes: [HostNotchTransferFinish] = []
    var operations: [String] = []
    var received: Data?
    var failFinish = false
    var cancelled = false
    var cancelCloses = true
    var finishDuringBegin = false
    var complete: HostNotchTransferProxy.Completion = { _, _, _ in }

    init() throws {
        _ = TestWindowHost.application
        panel = HostNotchPanel()
        let fixture = HostNotchStateFixture()
        state = fixture.state()
        identity = .init(ownershipID: state.ownershipID, generation: UUID())
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-shelf-incoming-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("synthetic.txt")
        try Data("synthetic shelf document".utf8).write(to: url)
        transfer = .init(
            id: UUID(), displayID: state.displayID, presentationID: state.presentationID,
            kind: .drag,
            items: [
                .init(id: UUID(), name: "synthetic.txt", addedAt: Date(timeIntervalSince1970: 1))
            ], fileURLs: [url])
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root); panel.close() }

    func proxy() -> HostNotchTransferProxy {
        .init(
            invoke: { [self] operation, payload, _ in
                operations.append(operation)
                if operation == "notch.panel.transfer.ack" {
                    let ack = try JSONDecoder().decode(
                        HostNotchTransferAcknowledgement.self, from: payload)
                    #expect(ack.opened && ack.identity == identity && ack.id == transfer.id)
                    acknowledgements.append(ack)
                } else if operation == "notch.panel.transfer.finish" {
                    finishes.append(
                        try JSONDecoder().decode(HostNotchTransferFinish.self, from: payload))
                    if failFinish { throw HostWorkerError.rejected }
                } else {
                    throw HostWorkerError.rejected
                }
                return Data("{}".utf8)
            },
            make: { [self] descriptor, actualPanel, completion in
                #expect(actualPanel === panel && descriptor == transfer && !actualPanel.isVisible)
                complete = completion
                return NotchTestNativeAction(
                    begin: { [self] in
                        received = try Data(contentsOf: descriptor.fileURLs[0])
                        if finishDuringBegin { completion(true, false, nil) }
                    },
                    cancel: { [self] in
                        cancelled = true; return cancelCloses
                    })
            })
    }

    func accept(_ proxy: HostNotchTransferProxy) throws {
        try proxy.accept([transfer], identity: identity, states: [state]) { _ in panel }
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class NotchTestNativeAction: HostNotchNativeAction {
    private let beginAction: () throws -> Void
    private let cancelAction: () -> Bool
    init(begin: @escaping () throws -> Void, cancel: @escaping () -> Bool) {
        beginAction = begin; cancelAction = cancel
    }
    func begin() throws { try beginAction() }
    func cancel() -> Bool { cancelAction() }
}
