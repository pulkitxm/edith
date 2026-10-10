import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarEngineBridgeTests {
    @Test func originalEngineRecordsAndActionsTravelThroughRegistryAndCheckedClient() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        let facade = try fixture.facade()
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        #expect(facade.events.map(\.id) == ["owned"])
        #expect(facade.events.first?.notes == "Synthetic notes")
        await facade.performAndWait(.join, eventID: "owned")
        await facade.performAndWait(.directions, eventID: "owned")
        await facade.performAndWait(.open)
        await facade.performAndWait(.permission)
        #expect(fixture.opened.map(\.host) == ["meet.google.com", "maps.apple.com", nil])
        #expect(fixture.grants == 1)
        try fixture.channel.publish(["active": "1", "blurCalendar": "1"])
        await facade.refreshAndWait()
        #expect(facade.blurEvents && facade.events.first?.title == "Meeting")
        #expect(facade.events.first?.notes == "Private notes")
        fixture.allowed = false
        await facade.refreshAndWait()
        #expect(!facade.authorized && facade.events.isEmpty)
        await facade.performAndWait(.join, eventID: "owned")
        #expect(facade.error != nil && fixture.opened.count == 3)
    }

    @Test func onePresentationCanDisappearWithoutDisablingOtherPresentations() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        let first = try fixture.facade()
        let second = try fixture.facade()
        defer { first.shutdown(); second.shutdown() }
        await first.refreshAndWait()
        first.suspend()
        await second.refreshAndWait()
        #expect(second.events.map(\.id) == ["owned"])
        first.shutdown()
        await second.performAndWait(.join, eventID: "owned")
        #expect(fixture.opened.count == 1 && second.authorized)
        #expect(fixture.engine.snapshot().authorized)
    }

    @Test func disablingEngineRejectsFurtherFacadeReadsAndActions() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        let facade = try fixture.facade()
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        fixture.engine.shutdown()
        await facade.performAndWait(.join, eventID: "owned")
        #expect(facade.error != nil && fixture.opened.isEmpty)
        facade.shutdown()
        #expect(facade.events.isEmpty && !facade.authorized && facade.blurEvents)
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let channel: ExtensionSharedState
        let presentation: CalendarPresentationState
        let store: CalendarStore
        let commands = ExtensionCommandRegistry()
        var allowed = true
        var grants = 0
        var opened: [URL] = []
        lazy var engine = CalendarUIEngine(
            store: store, presentation: presentation, authorized: { [unowned self] in allowed },
            open: { [unowned self] in
                opened.append($0); return true
            },
            grant: { [unowned self] in grants += 1 })

        init() {
            channel = ExtensionSharedState(root: root, namespace: "fixture", owner: "presenter")
            presentation = CalendarPresentationState(channel: channel)
            let event = CalendarEventPayload(
                id: "owned", title: "Synthetic owned event", calendar: "Synthetic calendar",
                calendarID: "one", start: Date(), end: Date().addingTimeInterval(600),
                isAllDay: false, location: "Synthetic hall",
                meetingURL: "https://meet.google.com/synthetic",
                notes: "Synthetic notes")
            store = CalendarStore(
                snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
                fetch: { _ in [event] })
        }

        func facade() throws -> CalendarUIFacade {
            let bridge = CalendarRegistryBridge(engine: engine, commands: commands)
            return CalendarUIFacade(
                client: try #require(
                    ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID)))
        }

        func stop() {
            engine.shutdown(); commands.shutdown(); store.shutdown(); presentation.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class CalendarRegistryBridge: NSObject {
    let presentationID = UUID()
    private let engine: CalendarUIEngine
    private let commands: ExtensionCommandRegistry

    init(engine: CalendarUIEngine, commands: ExtensionCommandRegistry) {
        self.engine = engine
        self.commands = commands
    }

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @convention(block) (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            try request.validate()
            guard request.presentationID == presentationID else {
                throw ExtensionEngineError.rejected
            }
            commands.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ] as NSDictionary,
                completion: { payload, error in
                    let reply = ExtensionEngineReply(
                        token: request.token, ok: error == nil,
                        payload: payload as Data? ?? Data("{}".utf8))
                    guard let data = try? ExtensionEngineWire.encode(reply) else { return }
                    completion(data as NSData)
                }
            ) { [engine] operation, payload in
                try await engine.execute(operation, payload: payload)
            }
        } catch { preconditionFailure(error.localizedDescription) }
    }

    @objc(cancel:)
    func cancel(_ token: NSString) { commands.cancel(token as String) }
}
