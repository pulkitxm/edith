import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import CalendarExtension

@MainActor @Suite(.serialized) struct CalendarFixtureBackendTests {
    @Test func admittedBackendFeedsOriginalScenesThroughRuntimeRegistryAndCheckedClient()
        async throws
    {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        let backend = CalendarFixtureBackend(admission: try #require(try fixture.admit()))
        let runtime = makeRuntime(backend)
        defer { _ = runtime.execute(["operation": "stop"]) }
        backend.store.start()
        #expect(backend.store.authStatus == .fullAccess)
        backend.store.refreshAuthStatus()
        for location in [CalendarUISceneRoute.Location.main, .home, .notch] {
            let bridge = CalendarFixtureRuntimeBridge(runtime: runtime)
            let client = try #require(
                ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID))
            let facade = CalendarUIFacade(client: client)
            defer { facade.shutdown() }
            await facade.refreshAndWait()
            #expect(facade.authorized && !facade.blurEvents)
            #expect(facade.events.map(\.id) == ["synthetic-calendar-meeting"])
            #expect(facade.events.first?.notes == "Synthetic agenda notes")
            let tile = SurfaceTile(.calendar)
            let scene = CalendarUIPresentation(
                facade: facade,
                route: .init(location: location, tile: location == .main ? nil : tile))
            defer { scene.shutdown() }
            let controller = try #require(scene.controller())
            switch location {
            case .main:
                #expect(controller is NSHostingController<ExtensionPageHost<CalendarPage>>)
            case .home:
                #expect(controller is NSHostingController<ExtensionPageHost<CalendarHomeScene>>)
            case .notch:
                #expect(controller is NSHostingController<ExtensionPageHost<CalendarNotchScene>>)
            }
            #expect(controller.view.window == nil)
            scene.shutdown()
            #expect(!facade.authorized && backend.store.authStatus == .fullAccess)
        }
        #expect(backend.opened.isEmpty && backend.grants == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.data.appendingPathComponent("Snapshots").path))
        await backend.store.stopAndWait()
    }

    @Test func syntheticCLIAndUIActionsResolveEngineRecordsWithoutAnyOSService() async throws {
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        let backend = CalendarFixtureBackend(admission: try #require(try fixture.admit()))
        let runtime = makeRuntime(backend)
        defer { _ = runtime.execute(["operation": "stop"]) }
        backend.store.start()
        let request = try ExtensionCLIRequest(
            arguments: ["ls", "--json", "--days", "30"],
            standardInput: Data("synthetic stdin".utf8),
            workingDirectory: fixture.home.path, interactive: true)
        let list = try await cli(runtime, request)
        #expect(list.exitCode == 0 && list.stderr.isEmpty)
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]])
        #expect(
            rows.map { $0["id"] as? String } == [
                "synthetic-calendar-meeting", "synthetic-calendar-next-page",
            ])
        #expect(rows.first?["title"] as? String == "Synthetic Calendar review")
        #expect(
            rows.first?["meetingURL"] as? String
                == "https://meet.google.com/synthetic-calendar-review")
        for arguments in [
            ["join", "synthetic-calendar-meeting", "--json"],
            ["route", "synthetic-calendar-meeting", "--json"], ["open", "--json"],
        ] {
            let reply = try await cli(runtime, .init(arguments: arguments))
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
        }
        #expect(backend.opened.count == 3)
        let missing = try await cli(runtime, .init(arguments: ["join", "foreign", "--json"]))
        #expect(missing.exitCode != 0 && backend.opened.count == 3)
        let bridge = CalendarFixtureRuntimeBridge(runtime: runtime)
        let facade = CalendarUIFacade(
            client: try #require(
                ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID)))
        defer { facade.shutdown() }
        await facade.refreshAndWait()
        await facade.performAndWait(.join, eventID: "synthetic-calendar-meeting")
        await facade.performAndWait(.directions, eventID: "synthetic-calendar-meeting")
        await facade.performAndWait(.open)
        await facade.performAndWait(.permission)
        #expect(backend.opened.count == 6 && backend.grants == 1)
        facade.loadMore()
        for _ in 0..<100 {
            if facade.events.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            facade.events.map(\.id) == [
                "synthetic-calendar-meeting", "synthetic-calendar-next-page",
            ])
        await facade.performAndWait(.join, eventID: "https://foreign.invalid")
        #expect(facade.error != nil && backend.opened.count == 6)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        await #expect(throws: (any Error).self) {
            try await cli(runtime, .init(arguments: ["ls"]))
        }
        await facade.refreshAndWait()
        #expect(facade.error != nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.data.appendingPathComponent("Snapshots").path))
    }

    @Test func independentCLIActionServicesStayScopedAcrossSuspendedRequests() async throws {
        var firstOpened: [URL] = []
        var secondOpened: [URL] = []
        let first = CalendarCLIActionServices(
            openURL: {
                firstOpened.append($0); return true
            }, openCalendar: { firstOpened.append($0) })
        let second = CalendarCLIActionServices(
            openURL: {
                secondOpened.append($0); return true
            }, openCalendar: { secondOpened.append($0) })
        let firstEvent = CalendarFixtureBackend.events(now: Date())[0]
        var secondEvent = firstEvent
        secondEvent.id = "second-synthetic"
        secondEvent.meetingURL = "https://meet.google.com/second-synthetic"
        let firstRequest = Task { @MainActor in
            try await CalendarCLIExecution.run(
                .init(arguments: ["join", firstEvent.id, "--json"]), actions: first
            ) { _ in
                for _ in 0..<5 { await Task.yield() }
                return [firstEvent]
            }
        }
        let secondReply = try await CalendarCLIExecution.run(
            .init(arguments: ["join", secondEvent.id, "--json"]), actions: second
        ) { _ in [secondEvent] }
        let firstReply = try await firstRequest.value
        #expect(firstReply.exitCode == 0 && secondReply.exitCode == 0)
        #expect(firstOpened.map(\.absoluteString) == [firstEvent.meetingURL!])
        #expect(secondOpened.map(\.absoluteString) == [secondEvent.meetingURL!])
    }

    @Test func originalSurfaceRoutesUseSyntheticSourcesAndIgnoreDiskSnapshots() async throws {
        let fixture = try CalendarAdmissionFixture()
        defer { fixture.remove() }
        let snapshot = fixture.data.appendingPathComponent("Snapshots/calendar-agenda.json")
        try FileManager.default.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let decoy = try JSONEncoder().encode([
            CalendarEventPayload(
                id: "decoy", title: "Synthetic disk snapshot must not load", start: Date(),
                end: Date().addingTimeInterval(3600), isAllDay: false)
        ])
        try decoy.write(to: snapshot)
        let backend = CalendarFixtureBackend(admission: try #require(try fixture.admit()))
        let runtime = makeRuntime(backend)
        defer { _ = runtime.execute(["operation": "stop"]) }
        backend.store.start()
        let bridge = CalendarFixtureRuntimeBridge(runtime: runtime)
        let client = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: bridge.presentationID))
        defer { client.invalidate() }
        var tile = SurfaceTile(.calendar)
        tile.sourceIDs = ["synthetic-work"]
        for target in [SurfaceTarget.home, .notch] {
            let request = SurfaceSnapshotRequest(target: target, tile: tile)
            let data = try await client.invoke(
                "surface.snapshot", payload: request.encoded(providerID: "calendar"))
            let result = try SurfaceSnapshot.decode(data, providerID: "calendar")
            #expect(result.rows.map(\.id) == ["synthetic-calendar-meeting"])
            #expect(result.rows.first?.title == "Synthetic Calendar review")
            #expect(result.sources.map(\.id) == ["synthetic-work"])
            let action = SurfaceActionRequest(
                snapshot: request, actionID: "join:synthetic-calendar-meeting")
            _ = try await client.invoke(
                "surface.perform", payload: action.encoded(providerID: "calendar"))
        }
        #expect(backend.opened.count == 2 && backend.grants == 0)
        tile.sourceIDs = ["foreign"]
        let invalid = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "join:synthetic-calendar-meeting")
        await #expect(throws: (any Error).self) {
            try await client.invoke(
                "surface.perform", payload: invalid.encoded(providerID: "calendar"))
        }
        await backend.store.stopAndWait()
        #expect(try Data(contentsOf: snapshot) == decoy)
        #expect(backend.store.events.map(\.id) == ["synthetic-calendar-meeting"])
    }

    private func makeRuntime(_ backend: CalendarFixtureBackend) -> ExtensionRuntime {
        ExtensionRuntime(
            store: backend.store, presentation: backend.presentation,
            uiEngine: backend.makeUIEngine(navigate: { _ in throw ExtensionPeerError.unavailable }),
            fixture: backend)
    }

    private func cli(_ runtime: ExtensionRuntime, _ request: ExtensionCLIRequest) async throws
        -> ExtensionCLIReply
    {
        let payload = try JSONEncoder().encode(request)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            runtime.invoke([
                "token": UUID().uuidString, "command": "calendar.cli", "payload": payload,
            ]) { data, error in
                if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(
                        throwing: ExtensionPeerError.rejected(error as String? ?? "No reply"))
                }
            }
        }
        return try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
    }
}

@MainActor
private final class CalendarFixtureRuntimeBridge: NSObject {
    let presentationID = UUID()
    private let runtime: ExtensionRuntime

    init(runtime: ExtensionRuntime) { self.runtime = runtime }

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @convention(block) (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            try request.validate()
            guard request.presentationID == presentationID else {
                throw ExtensionEngineError.rejected
            }
            runtime.invoke([
                "token": request.token.uuidString, "command": request.operation,
                "payload": request.payload,
            ]) { payload, error in
                let reply = ExtensionEngineReply(
                    token: request.token, ok: error == nil,
                    payload: payload as Data? ?? Data("{}".utf8))
                guard let data = try? ExtensionEngineWire.encode(reply) else { return }
                completion(data as NSData)
            }
        } catch { preconditionFailure(error.localizedDescription) }
    }

    @objc(cancel:)
    func cancel(_ token: NSString) {
        _ = runtime.execute(["operation": "cancelCommand", "token": token])
    }
}
