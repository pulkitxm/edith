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
