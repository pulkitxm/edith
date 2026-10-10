import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarNavigationTests {
    @Test func checkedUIAndEngineEmitOnlyTheConfiguredCalendarPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = CalendarNavigationTestHost()
        let navigation = try #require(CalendarHostNavigation(bridge: host))
        defer { navigation.invalidate() }
        let store = CalendarStore(
            snapshotStore: .init(file: root.appendingPathComponent("agenda.json")),
            fetch: { _ in [] })
        defer { store.shutdown() }
        let presentation = CalendarPresentationState(channel: nil)
        defer { presentation.shutdown() }
        let engine = CalendarUIEngine(
            store: store, presentation: presentation, authorized: { false },
            navigate: navigation.navigate)
        defer { engine.shutdown() }
        let registry = ExtensionCommandRegistry()
        defer { registry.shutdown() }
        let bridge = CalendarNavigationEngineBridge(engine: engine, registry: registry)
        let client = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID))
        let request = CalendarNavigationRequest(
            presentationID: bridge.presentationID, location: "notch")
        let facade = CalendarUIFacade(client: client, navigation: request)
        defer { facade.shutdown() }
        let open = Task { await facade.openPageAndWait() }
        await host.entered()
        let input = try #require(host.requests.first)
        #expect(input == request.dictionary)
        #expect(!open.isCancelled)
        host.complete(nil)
        await open.value
        #expect(facade.error == nil && host.cancelled.isEmpty)
        for payload in [
            Data("{}".utf8),
            Data("{\"presentationID\":\"bad\",\"location\":\"home\"}".utf8),
            try JSONEncoder().encode(
                CalendarNavigationRequest(presentationID: bridge.presentationID, location: "main")),
            Data(
                "{\"presentationID\":\"\(bridge.presentationID)\",\"location\":\"home\",\"url\":\"https://example.invalid\"}"
                    .utf8),
        ] {
            await #expect(throws: (any Error).self) {
                try await engine.execute("calendar.ui.navigate", payload: payload)
            }
        }
        #expect(host.requests.count == 1)
    }

    @Test func disappearanceCancelsTheExactHostTokenAndLateAckCannotReviveIt() async throws {
        let host = CalendarNavigationTestHost()
        let navigation = try #require(CalendarHostNavigation(bridge: host))
        let request = CalendarNavigationRequest(presentationID: UUID(), location: "home")
        let task = Task { try await navigation.navigate(request) }
        await host.entered()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(host.cancelled == [host.token.uuidString])
        host.complete(nil)
        await navigation.stopAndWait()
        await #expect(throws: (any Error).self) { try await navigation.navigate(request) }
        #expect(host.requests.count == 1)
    }

    @Test func hostRejectionAndMissingStartupCallbackStayUnavailable() async throws {
        #expect(CalendarHostNavigation(bridge: NSObject()) == nil)
        let host = CalendarNavigationTestHost()
        let navigation = try #require(CalendarHostNavigation(bridge: host))
        defer { navigation.invalidate() }
        let task = Task {
            try await navigation.navigate(.init(presentationID: UUID(), location: "home"))
        }
        await host.entered()
        host.complete("The owning window is unavailable.")
        await #expect(throws: (any Error).self) { try await task.value }
    }
}

@MainActor private final class CalendarNavigationTestHost: NSObject {
    let token = UUID()
    var requests: [NSDictionary] = []
    var cancelled: [String] = []
    private var completion: ((NSString?) -> Void)?

    @objc(navigate:completion:)
    func navigate(_ input: NSDictionary, completion: @escaping (NSString?) -> Void) -> NSString? {
        requests.append(input)
        self.completion = completion
        return token.uuidString as NSString
    }

    @objc(cancelNavigation:)
    func cancelNavigation(_ token: NSString) { cancelled.append(token as String) }

    func entered() async {
        while requests.isEmpty { await Task.yield() }
    }

    func complete(_ error: NSString?) { completion?(error) }
}

@MainActor private final class CalendarNavigationEngineBridge: NSObject {
    let presentationID = UUID()
    let engine: CalendarUIEngine
    let registry: ExtensionCommandRegistry

    init(engine: CalendarUIEngine, registry: ExtensionCommandRegistry) {
        self.engine = engine
        self.registry = registry
    }

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @convention(block) (NSData) -> Void) {
        let request = try! ExtensionEngineWire.decode(
            ExtensionEngineRequest.self, from: data as Data)
        try! request.validate()
        #expect(request.presentationID == presentationID)
        registry.invoke(
            [
                "token": request.token.uuidString, "command": request.operation,
                "payload": request.payload,
            ]
        ) { data, message in
            let reply = ExtensionEngineReply(
                token: request.token, ok: data != nil && message == nil,
                payload: data as Data? ?? Data())
            completion(try! ExtensionEngineWire.encode(reply) as NSData)
        } execute: { [engine] operation, payload in
            try await engine.execute(operation, payload: payload)
        }
    }

    @objc(cancel:)
    func cancel(_ token: NSString) { registry.cancel(token as String) }
}
