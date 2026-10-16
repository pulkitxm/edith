import AppKit
import SwiftUI
import Testing
@testable import EdithExtensionUI

@Suite(.serialized)
@MainActor
struct OwnedExportDeliveryTests {
    private struct Card: Identifiable, Hashable {
        let id = "synthetic"
    }

    private struct Deck: ExportCardDeck {
        let cards = [Card()]
        var delivery: (@MainActor (Data, String, Bool) async throws -> String)?
        func title(for card: Card) -> String { "Synthetic report" }
        func filename(for card: Card) -> String { "synthetic-report.png" }
        func content(for card: Card) -> some View {
            ZStack {
                Color.blue; Text("Synthetic report").foregroundStyle(.white)
            }
        }
    }

    private struct LocalDeck: ExportCardDeck {
        let cards = [Card()]
        func title(for card: Card) -> String { "Local report" }
        func filename(for card: Card) -> String { "local-report.png" }
        func content(for card: Card) -> some View { Color.green }
    }

    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Synthetic delivery unavailable" }
    }

    private final class DeferredDelivery {
        var continuation: CheckedContinuation<String, Error>?
        var returned = false
        var cancelled = false

        func wait() async throws -> String {
            defer {
                returned = true
                cancelled = Task.isCancelled
            }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func owningCallbackReceivesExactPNGFilenameAndCopyOrSaveWithoutLocalDelivery()
        async throws
    {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init("owned-export-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Synthetic sentinel", forType: .string)
        let changeCount = pasteboard.changeCount
        var requests: [(Data, String, Bool)] = []
        let deck = Deck { data, filename, save in
            requests.append((data, filename, save))
            return save ? "Engine saved PNG" : "Engine copied PNG"
        }
        var rendered: [Data] = []
        for save in [false, true] {
            let result = try #require(
                try await ExportCardDelivery.perform(
                    deck: deck, card: deck.cards[0], save: save,
                    chooseSaveURL: { _ in
                        Issue.record("Local save panel path used"); return nil
                    },
                    write: { _, _ in Issue.record("Local file path used") },
                    copy: { try ExportDelivery.copyPNG($0, to: pasteboard) },
                    render: {
                        let data = try ExportCardRenderer.pngData($0)
                        rendered.append(data)
                        return data
                    }))
            #expect(result.status.message == (save ? "Engine saved PNG" : "Engine copied PNG"))
            #expect(!result.status.failed)
            #expect(result.copied == !save)
        }
        #expect(requests.count == 2)
        #expect(rendered.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.0 == rendered[index])
            #expect(request.1 == "synthetic-report.png")
            #expect(request.2 == (index == 1))
            let bitmap = try #require(NSBitmapImageRep(data: request.0))
            #expect(bitmap.pixelsWide == 2_400 && bitmap.pixelsHigh == 1_600)
            #expect(request.0.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        }
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "Synthetic sentinel")
    }

    @Test func absentCallbackPreservesLocalPNGCopyAndAtomicSave() async throws {
        _ = NSApplication.shared
        let deck = LocalDeck()
        #expect(deck.delivery == nil)
        let pasteboard = NSPasteboard(name: .init("local-export-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-report-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let copied = try #require(
            try await ExportCardDelivery.perform(
                deck: deck, card: deck.cards[0], save: false,
                chooseSaveURL: { _ in
                    Issue.record("Copy selected a save destination"); return nil
                },
                copy: { try ExportDelivery.copyPNG($0, to: pasteboard) }))
        #expect(copied.copied && copied.status.message == "Image copied")
        let data = try #require(pasteboard.data(forType: .png))
        let saved = try #require(
            try await ExportCardDelivery.perform(
                deck: deck, card: deck.cards[0], save: true,
                chooseSaveURL: { name in
                    #expect(name == "local-report.png")
                    return url
                },
                copy: { _ in Issue.record("Save wrote to pasteboard") }))
        #expect(!saved.copied && saved.status.message == "Saved to \(url.lastPathComponent)")
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func cancelledLocalSaveHasNoDeliveryOrStatus() async throws {
        let deck = LocalDeck()
        let result = try await ExportCardDelivery.perform(
            deck: deck, card: deck.cards[0], save: true,
            chooseSaveURL: { _ in nil },
            write: { _, _ in Issue.record("Cancelled save wrote file") },
            copy: { _ in Issue.record("Cancelled save copied image") })
        #expect(result == nil)
    }

    @Test func alreadyCancelledActionNeverInvokesOwnerOrLocalServices() async {
        let deck = Deck { _, _, _ in
            Issue.record("Cancelled action reached owner")
            return "Unexpected"
        }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ExportCardDelivery.perform(
                    deck: deck, card: deck.cards[0], save: true,
                    chooseSaveURL: { _ in
                        Issue.record("Cancelled action chose a path"); return nil
                    },
                    copy: { _ in Issue.record("Cancelled action copied") })
                Issue.record("Cancelled action completed")
            } catch is CancellationError {
            } catch { Issue.record("Unexpected error: \(error)") }
        }
        await task.value
    }

    @Test func callbackFailurePublishesFailedStatusAndFinishesAction() async throws {
        _ = NSApplication.shared
        let deck = Deck { _, _, _ in throw Failure.unavailable }
        let action = ExportCardAction()
        var completion = false
        var status: ExportCardStatus?
        action.start {
            try await ExportCardDelivery.perform(
                deck: deck, card: deck.cards[0], save: false,
                chooseSaveURL: { _ in
                    Issue.record("Owner failure chose a path"); return nil
                },
                copy: { _ in Issue.record("Owner failure copied locally") })
        } completion: {
            status = $0?.status
            completion = true
        }
        try await until { completion }
        #expect(status?.failed == true)
        #expect(status?.message == "Synthetic delivery unavailable")
    }

    @Test func selfCancelledOwnerFinishesActionWithoutPublishingLateFailure() async throws {
        _ = NSApplication.shared
        let deck = Deck { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw Failure.unavailable
        }
        let action = ExportCardAction()
        var completed = false
        var result: ExportCardDeliveryResult?
        action.start {
            try await ExportCardDelivery.perform(
                deck: deck, card: deck.cards[0], save: false,
                chooseSaveURL: { _ in
                    Issue.record("Cancelled owner chose local path"); return nil
                },
                copy: { _ in Issue.record("Cancelled owner copied locally") })
        } completion: {
            result = $0
            completed = true
        }
        try await until { completed }
        #expect(result == nil)
    }

    @Test(arguments: [false, true])
    func cancelledCallbackLateSuccessOrFailureCannotPublishStatusOrFinishNewAction(
        lateFailure: Bool
    ) async throws {
        _ = NSApplication.shared
        let old = DeferredDelivery()
        let next = DeferredDelivery()
        let action = ExportCardAction()
        var completions: [String] = []
        func start(_ delivery: DeferredDelivery, label: String) {
            let deck = Deck { _, _, _ in try await delivery.wait() }
            action.start {
                try await ExportCardDelivery.perform(
                    deck: deck, card: deck.cards[0], save: false,
                    chooseSaveURL: { _ in
                        Issue.record("Owner selected local path"); return nil
                    },
                    copy: { _ in Issue.record("Owner copied locally") })
            } completion: {
                completions.append("\(label):\($0?.status.message ?? "cancelled")")
            }
        }
        start(old, label: "old")
        try await until { old.continuation != nil }
        action.cancel()
        start(next, label: "next")
        try await until { next.continuation != nil }
        if lateFailure {
            old.continuation?.resume(throwing: Failure.unavailable)
        } else {
            old.continuation?.resume(returning: "Late success")
        }
        try await until { old.returned }
        #expect(old.cancelled)
        #expect(completions.isEmpty)
        next.continuation?.resume(returning: "Current delivery")
        try await until { completions.count == 1 }
        #expect(completions == ["next:Current delivery"])
    }

    @Test func disappearingActionCancelsOwnerAndIgnoresLateReply() async throws {
        _ = NSApplication.shared
        let owner = DeferredDelivery()
        var action: ExportCardAction? = ExportCardAction()
        var completed = false
        let deck = Deck { _, _, _ in try await owner.wait() }
        action?.start {
            try await ExportCardDelivery.perform(
                deck: deck, card: deck.cards[0], save: true,
                chooseSaveURL: { _ in
                    Issue.record("Owner chose local path"); return nil
                },
                copy: { _ in Issue.record("Owner copied locally") })
        } completion: { _ in
            completed = true
        }
        try await until { owner.continuation != nil }
        action = nil
        owner.continuation?.resume(returning: "Late reply")
        try await until { owner.returned }
        #expect(owner.cancelled)
        #expect(!completed)
    }
}
