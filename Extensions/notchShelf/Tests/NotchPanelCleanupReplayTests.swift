import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchPanelCleanupReplayTests {
    @Test func lostTransferReplyReplaysOnlyExactOutcomeAndDoesNotReleaseNextSelection() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("owned native transfer"))
        let transfer = try beginTransfer(fixture, item: item)
        let receipt = NotchPanelTransferFinish(
            identity: identity, id: transfer.id, completed: true, outside: false, error: nil)
        try fixture.engine.finishTransfer(receipt)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURLs[0].path))
        let revision = fixture.engine.revision
        try fixture.engine.finishTransfer(receipt)
        #expect(fixture.engine.revision == revision)
        for wrong in [
            NotchPanelTransferFinish(
                identity: foreign(identity), id: transfer.id, completed: true, outside: false,
                error: nil),
            .init(identity: identity, id: UUID(), completed: true, outside: false, error: nil),
            .init(
                identity: identity, id: transfer.id, completed: false, outside: false, error: nil),
            .init(identity: identity, id: transfer.id, completed: true, outside: true, error: nil),
            .init(
                identity: identity, id: transfer.id, completed: true, outside: false,
                error: "changed outcome"),
        ] {
            #expect(throws: (any Error).self) { try fixture.engine.finishTransfer(wrong) }
        }
        let next = try beginTransfer(fixture, item: item)
        try fixture.engine.finishTransfer(receipt)
        #expect(try fixture.engine.batch().transfers.first?.id == next.id)
        #expect(controller.store.addText("must remain pinned") == nil)
        #expect(
            try String(contentsOf: next.fileURLs[0], encoding: .utf8) == "owned native transfer")
        try fixture.engine.finishTransfer(
            .init(identity: identity, id: next.id, completed: false, outside: false, error: nil))
        #expect(controller.store.addText("selection drained") != nil)
    }

    @Test func duplicatedDragCleanupPreservesOriginalRemovalDeadline() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("original drag removal"))
        controller.synchronizeShelfItems()
        try fixture.engine.action(
            .init(
                identity: identity, displayID: 42, presentationID: fixture.presentation,
                revision: fixture.engine.revision, operation: .drag, itemID: item.id))
        let transfer = try #require(try fixture.engine.batch().transfers.first)
        let receipt = NotchPanelTransferFinish(
            identity: identity, id: transfer.id, completed: true, outside: true, error: nil)
        try fixture.engine.finishTransfer(receipt)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURLs[0].path))
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.store.items.contains { $0.id == item.id })
        try fixture.engine.finishTransfer(receipt)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!controller.store.items.contains { $0.id == item.id })
        #expect(!FileManager.default.fileExists(atPath: controller.store.fileURL(for: item).path))
        try fixture.engine.finishTransfer(receipt)
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func pendingDisableAcceptsOnlyIssuedCleanupAndExactReceipts() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("disable cleanup fixture"))
        let transfer = try beginTransfer(fixture, item: item)
        try fixture.publish([:])
        let receipt = NotchPanelTransferFinish(
            identity: identity, id: transfer.id, completed: false, outside: false,
            error: "native action canceled")
        try fixture.engine.finishTransfer(receipt)
        try fixture.engine.finishTransfer(receipt)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURLs[0].path))
        #expect(throws: (any Error).self) { try beginTransfer(fixture, item: item) }
        #expect(throws: (any Error).self) { try fixture.engine.preparePromise(promise(fixture)) }
        #expect(throws: (any Error).self) {
            try fixture.engine.drop(
                .init(
                    identity: identity, displayID: 42, presentationID: fixture.presentation,
                    fileURLs: [], text: "new work", x: nil, y: nil))
        }
        try fixture.engine.detach(identity)
        #expect(throws: (any Error).self) { try fixture.engine.finishTransfer(receipt) }
    }

    @Test func multiFilePromiseAdoptionDrainsBeforeExactLostReplyReplay() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        let issued = (0..<3).map { _ in promise(fixture) }
        let roots = try issued.map { try fixture.engine.preparePromise($0) }
        let names = ["first.txt", "second.txt", "third.txt"]
        for (index, name) in names.enumerated() {
            try Data("promised fixture \(index)".utf8).write(
                to: roots[0].appendingPathComponent(name))
        }
        for index in 1..<3 {
            try FileManager.default.copyItem(
                at: roots[0].appendingPathComponent(names[index]),
                to: roots[index].appendingPathComponent(names[index]))
        }
        let receipts = issued.enumerated().map { index, request in
            finished(request, fileURL: roots[index].appendingPathComponent(names[index]))
        }
        for receipt in receipts { try fixture.engine.finishPromise(receipt) }
        let revision = fixture.engine.revision
        for receipt in receipts { try fixture.engine.finishPromise(receipt) }
        #expect(fixture.engine.revision == revision)
        #expect(controller.items.count == 3)
        for (index, name) in names.enumerated() {
            let item = try #require(controller.items.first { $0.name == name })
            #expect(item.position == CGPoint(x: 50, y: 60))
            #expect(
                try String(contentsOf: controller.store.fileURL(for: item), encoding: .utf8)
                    == "promised fixture \(index)")
            #expect(!FileManager.default.fileExists(atPath: roots[index].path))
        }
        let first = receipts[0]
        for wrong in [
            finished(first, identity: foreign(first.identity)),
            finished(first, id: UUID()),
            finished(first, fileURL: nil),
            finished(first, fileURL: roots[0].appendingPathComponent("different.txt")),
            NotchPanelPromise(
                identity: first.identity, displayID: 42, presentationID: UUID(), id: first.id,
                fileURL: first.fileURL, x: first.x, y: first.y),
            NotchPanelPromise(
                identity: first.identity, displayID: 42, presentationID: first.presentationID,
                id: first.id, fileURL: first.fileURL, x: 51, y: first.y),
        ] {
            #expect(throws: (any Error).self) { try fixture.engine.finishPromise(wrong) }
        }
        #expect(throws: (any Error).self) { try fixture.engine.preparePromise(issued[0]) }
        try fixture.publish([:])
        for receipt in receipts { try fixture.engine.finishPromise(receipt) }
        #expect(controller.items.count == 3)
    }

    @Test func pendingPromiseCannotAcknowledgeUntilRetainedSelectionDrains() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("retained original item"))
        let issued = promise(fixture)
        let root = try fixture.engine.preparePromise(issued)
        let received = root.appendingPathComponent("deferred.txt")
        try Data("actual deferred adoption".utf8).write(to: received)
        let transfer = try beginTransfer(fixture, item: item)
        let receipt = finished(issued, fileURL: received)
        #expect(throws: (any Error).self) { try fixture.engine.finishPromise(receipt) }
        #expect(throws: (any Error).self) { try fixture.engine.finishPromise(receipt) }
        #expect(throws: (any Error).self) {
            try fixture.engine.finishPromise(finished(receipt, fileURL: nil))
        }
        #expect(FileManager.default.fileExists(atPath: received.path))
        #expect(!controller.items.contains { $0.name == "deferred.txt" })
        try fixture.publish([:])
        #expect(throws: (any Error).self) { try fixture.engine.preparePromise(promise(fixture)) }
        try fixture.engine.finishTransfer(
            .init(identity: identity, id: transfer.id, completed: false, outside: false, error: nil)
        )
        try fixture.engine.finishPromise(receipt)
        try fixture.engine.finishPromise(receipt)
        let adopted = try #require(controller.items.first { $0.name == "deferred.txt" })
        #expect(
            try String(contentsOf: controller.store.fileURL(for: adopted), encoding: .utf8)
                == "actual deferred adoption")
        #expect(adopted.position == CGPoint(x: 50, y: 60))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(controller.items.count == 2)
    }

    @Test func pendingDisableDiscardsIssuedPromiseOnceAndReplaysCancellation() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        _ = try fixture.attach()
        let controller = fixture.bind()
        let issued = promise(fixture)
        let root = try fixture.engine.preparePromise(issued)
        let received = root.appendingPathComponent("canceled.txt")
        try Data("owned canceled writer".utf8).write(to: received)
        try fixture.publish([:])
        for invalid in [
            URL(string: "https://example.invalid/not-a-promised-file")!,
            URL(fileURLWithPath: "/" + String(repeating: "x", count: 4096)),
            root.appendingPathComponent("invalid\0name"),
        ] {
            #expect(throws: (any Error).self) {
                try fixture.engine.finishPromise(finished(issued, fileURL: invalid))
            }
            #expect(FileManager.default.fileExists(atPath: received.path))
        }
        let receipt = finished(issued, fileURL: received)
        try fixture.engine.finishPromise(receipt)
        try fixture.engine.finishPromise(receipt)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(controller.items.isEmpty)
        #expect(throws: (any Error).self) {
            try fixture.engine.finishPromise(finished(receipt, fileURL: nil))
        }
    }

    @Test func receiptsAreBoundedAndLateCleanupCannotCrossGeneration() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        let item = try #require(controller.store.addText("bounded receipts"))
        var firstTransfer: NotchPanelTransferFinish?
        var latestTransfer: NotchPanelTransferFinish?
        var firstPromise: NotchPanelPromise?
        var latestPromise: NotchPanelPromise?
        for _ in 0...NotchPanelEngine.maximumCleanupReceipts {
            let transfer = try beginTransfer(fixture, item: item)
            let receipt = NotchPanelTransferFinish(
                identity: identity, id: transfer.id, completed: false, outside: false, error: nil)
            try fixture.engine.finishTransfer(receipt)
            firstTransfer = firstTransfer ?? receipt; latestTransfer = receipt
            let issued = promise(fixture)
            let root = try fixture.engine.preparePromise(issued)
            try fixture.engine.finishPromise(issued)
            #expect(!FileManager.default.fileExists(atPath: root.path))
            firstPromise = firstPromise ?? issued; latestPromise = issued
        }
        let oldTransfer = try #require(firstTransfer)
        let oldPromise = try #require(firstPromise)
        #expect(throws: (any Error).self) { try fixture.engine.finishTransfer(oldTransfer) }
        #expect(throws: (any Error).self) { try fixture.engine.finishPromise(oldPromise) }
        let recentTransfer = try #require(latestTransfer)
        let recentPromise = try #require(latestPromise)
        try fixture.engine.finishTransfer(recentTransfer)
        try fixture.engine.finishPromise(recentPromise)
        let display = try #require(fixture.engine.displays[42])
        try fixture.engine.detach(identity)
        #expect(throws: (any Error).self) { try fixture.engine.finishTransfer(recentTransfer) }
        #expect(throws: (any Error).self) { try fixture.engine.finishPromise(recentPromise) }
        let next = NotchPanelEngine(
            context: fixture.context, connectedDisplays: { [42: CGSize(width: 1280, height: 900)] })
        defer { next.stop() }
        let generation = try next.attach(
            .init(ownershipID: fixture.ownership, version: "1", displays: [display])
        ).identity
        next.bind(controller)
        #expect(generation.ownershipID == identity.ownershipID)
        #expect(generation.generation != identity.generation)
        #expect(throws: (any Error).self) { try next.finishTransfer(recentTransfer) }
        #expect(throws: (any Error).self) { try next.finishPromise(recentPromise) }
        let issued = NotchPanelPromise(
            identity: generation, displayID: 42, presentationID: fixture.presentation,
            id: recentPromise.id, fileURL: nil, x: 50, y: 60)
        let root = try next.preparePromise(issued)
        #expect(throws: (any Error).self) { try next.finishPromise(recentPromise) }
        #expect(FileManager.default.fileExists(atPath: root.path))
        try next.finishPromise(issued)
        try next.finishPromise(issued)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func beginTransfer(_ fixture: NotchPanelFixture, item: ShelfItem) throws
        -> NotchPanelTransfer
    {
        fixture.controller?.synchronizeShelfItems()
        try fixture.engine.action(
            .init(
                identity: try #require(fixture.engine.identity), displayID: 42,
                presentationID: fixture.presentation, revision: fixture.engine.revision,
                operation: .share, itemID: item.id))
        return try #require(try fixture.engine.batch().transfers.first)
    }

    private func promise(_ fixture: NotchPanelFixture) -> NotchPanelPromise {
        .init(
            identity: fixture.engine.identity!, displayID: 42, presentationID: fixture.presentation,
            id: UUID(), fileURL: nil, x: 50, y: 60)
    }

    private func finished(
        _ request: NotchPanelPromise, identity: NotchPanelIdentity? = nil, id: UUID? = nil,
        fileURL: URL? = nil
    ) -> NotchPanelPromise {
        .init(
            identity: identity ?? request.identity, displayID: request.displayID,
            presentationID: request.presentationID, id: id ?? request.id, fileURL: fileURL,
            x: request.x, y: request.y)
    }

    private func foreign(_ identity: NotchPanelIdentity) -> NotchPanelIdentity {
        .init(ownershipID: UUID(), generation: identity.generation)
    }
}
