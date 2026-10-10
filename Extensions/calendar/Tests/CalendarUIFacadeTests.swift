import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarUIFacadeTests {
    @Test func checkedClientPreservesDetailsAndSendsEventIdentityInsteadOfURLs() async throws {
        let bridge = CalendarTestEngineBridge()
        let client = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID))
        let facade = CalendarUIFacade(client: client)
        defer { facade.shutdown() }
        #expect(!facade.authorized && facade.blurEvents && facade.events.isEmpty)
        await facade.refreshAndWait()
        #expect(facade.authorized && !facade.blurEvents && facade.loaded)
        #expect(facade.events.first?.notes == "Synthetic notes")
        #expect(facade.groupedDays.count == 1)
        await facade.performAndWait(.join, eventID: "synthetic-event")
        let action = try #require(bridge.requests.last)
        #expect(action.operation == "calendar.ui.action")
        let payload = try JSONDecoder().decode(CalendarUIActionRequest.self, from: action.payload)
        #expect(payload.action == .join && payload.eventID == "synthetic-event")
        #expect(!String(decoding: action.payload, as: UTF8.self).contains("https"))
        facade.shutdown()
        await facade.refreshAndWait()
        #expect(bridge.requests.count == 2 && !facade.authorized && facade.events.isEmpty)
    }
    @Test func aLateResponseCannotUndoNewerPrivacyOrPermissionState() async throws {
        let gate = CalendarFacadeReadGate()
        var reads = 0
        let facade = CalendarUIFacade(invoke: { _, _ in
            reads += 1
            if reads == 1 { return await gate.wait() }
            return try JSONEncoder().encode(
                CalendarUISnapshot(
                    authorized: false, blurEvents: true, days: 14, events: []))
        })
        defer { facade.shutdown() }
        let first = Task { await facade.refreshAndWait() }
        await gate.entered()
        await facade.refreshAndWait()
        let event = CalendarEventPayload(
            id: "stale", title: "Synthetic stale private event", start: Date(),
            end: Date().addingTimeInterval(600), isAllDay: false)
        gate.release(
            try JSONEncoder().encode(
                CalendarUISnapshot(
                    authorized: true, blurEvents: false, days: 14, events: [event])))
        await first.value
        #expect(facade.loaded && !facade.authorized && facade.blurEvents && facade.events.isEmpty)
    }

    @Test func suspendRejectsAnIgnoringRequestWithoutInvalidatingThePresentation() async throws {
        let gate = CalendarFacadeReadGate()
        var invalidated = 0
        let facade = CalendarUIFacade(
            invoke: { _, _ in await gate.wait() }, invalidate: { invalidated += 1 })
        let task = Task { await facade.refreshAndWait() }
        await gate.entered()
        facade.suspend()
        gate.release(
            try JSONEncoder().encode(
                CalendarUISnapshot(
                    authorized: true, blurEvents: false, days: 14, events: [])))
        await task.value
        #expect(!facade.loaded && invalidated == 0)
        facade.shutdown()
        facade.shutdown()
        #expect(invalidated == 1)
    }

    @Test func stoppingCancelsTheCheckedClientAndIgnoresItsLateCompletion() async throws {
        let bridge = CalendarDelayedBridge()
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = CalendarUIFacade(client: client)
        let task = Task { await facade.refreshAndWait() }
        await bridge.entered()
        facade.shutdown()
        await task.value
        #expect(bridge.cancelled.count == 1)
        bridge.complete()
        await Task.yield()
        #expect(facade.events.isEmpty && !facade.loaded && !facade.authorized && facade.blurEvents)
    }

    @Test func aReplyFromAnotherClientRequestIsRejectedBeforeRendering() async throws {
        let bridge = CalendarDelayedBridge()
        let facade = CalendarUIFacade(
            client: try #require(
                ExtensionEngineClient(bridge: bridge, presentationID: UUID())))
        defer { facade.shutdown() }
        let task = Task { await facade.refreshAndWait() }
        await bridge.entered()
        bridge.complete(token: UUID())
        await task.value
        #expect(facade.error != nil && !facade.loaded && facade.events.isEmpty && facade.blurEvents)
    }

    @Test func invalidSnapshotCannotRenderSensitiveData() async throws {
        let event = CalendarEventPayload(
            id: "invalid", title: "Synthetic inaccessible event", start: Date(), end: Date(),
            isAllDay: false)
        let facade = CalendarUIFacade(invoke: { _, _ in
            try JSONEncoder().encode(
                CalendarUISnapshot(
                    authorized: false, blurEvents: false, days: 14, events: [event]))
        })
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        #expect(facade.error != nil && !facade.loaded && facade.events.isEmpty && facade.blurEvents)
    }

}

@MainActor
private final class CalendarTestEngineBridge: NSObject {
    let presentationID = UUID()
    var requests: [ExtensionEngineRequest] = []

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @convention(block) (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            try request.validate()
            guard request.presentationID == presentationID else {
                throw ExtensionEngineError.rejected
            }
            requests.append(request)
            let event = CalendarEventPayload(
                id: "synthetic-event", title: "Synthetic meeting", calendar: "Synthetic calendar",
                calendarID: "synthetic-calendar", start: Date(),
                end: Date().addingTimeInterval(600),
                isAllDay: false, meetingURL: "https://meet.google.com/synthetic",
                notes: "Synthetic notes")
            let snapshot = CalendarUISnapshot(
                authorized: true, blurEvents: false, days: 14, events: [event])
            let reply = ExtensionEngineReply(
                token: request.token, ok: true, payload: try JSONEncoder().encode(snapshot))
            completion(try ExtensionEngineWire.encode(reply) as NSData)
        } catch { preconditionFailure(error.localizedDescription) }
    }

    @objc(cancel:)
    func cancel(_ token: NSString) {}
}

@MainActor
private final class CalendarFacadeReadGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func wait() async -> Data {
        await withCheckedContinuation {
            continuation = $0
            hasEntered = true
            waiting?.resume()
            waiting = nil
        }
    }

    func entered() async {
        if hasEntered { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
private final class CalendarDelayedBridge: NSObject {
    private var completion: (@convention(block) (NSData) -> Void)?
    private var token: UUID?
    private var waiting: CheckedContinuation<Void, Never>?
    var cancelled: [String] = []

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @convention(block) (NSData) -> Void) {
        token = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data as Data)
            .token
        self.completion = completion
        waiting?.resume()
        waiting = nil
    }

    @objc(cancel:)
    func cancel(_ token: NSString) { cancelled.append(token as String) }

    func entered() async {
        if completion != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func complete(token override: UUID? = nil) {
        guard let storedToken = token, let completion else { return }
        let token = override ?? storedToken
        let snapshot = CalendarUISnapshot(authorized: true, blurEvents: false, days: 14, events: [])
        let reply = ExtensionEngineReply(
            token: token, ok: true, payload: try! JSONEncoder().encode(snapshot))
        completion(try! ExtensionEngineWire.encode(reply) as NSData)
        self.completion = nil
    }
}
