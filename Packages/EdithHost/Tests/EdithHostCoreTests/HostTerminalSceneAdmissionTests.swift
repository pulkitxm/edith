import Foundation
import Testing
import ExtensionMarketplace

@testable import EdithHostCore

@Suite @MainActor struct HostTerminalSceneAdmissionTests {
    @Test func closedOwnersAndExactHerdrTargetsAdmitOnlySealedRequests() throws {
        for (owner, location) in [
            ("terminal", "main"), ("herdr", "main"), ("herdr", "herdr.agent"),
            ("herdr", "herdr.space"), ("quinjet", "main"),
        ] {
            let request = try scene(owner, location)
            #expect(HostTerminalUIRequest.accepts(request))
            let session = UUID()
            let status = HostTerminalUIRequest(
                session: session, request: request, operation: .status)
            _ = try HostTerminalUIRequest.decode(
                status.encoded(), session: session, request: request, operation: "terminalUIStatus")
        }
        for owner in ["herdr", "quinjet", "terminal", "music", "machines"] {
            for location in ["settings", "home", "herdr.agent", "herdr.space"] {
                let request = HostExtensionContentRequest(extensionID: owner, location: location)
                #expect(!HostTerminalUIRequest.accepts(request))
            }
        }
        let request = try scene("herdr", "main")
        let session = UUID()
        let input = HostTerminalUIRequest(
            session: session, request: request, operation: .update,
            event: .init(
                presentationID: request.presentationID, sequence: 1, active: false, key: false,
                visible: false))
        var fields = try #require(
            JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        var event = try #require(fields["event"] as? [String: Any])
        event["command"] = "filesystem.open"; fields["event"] = event
        #expect(throws: (any Error).self) {
            try HostTerminalUIRequest.decode(
                JSONSerialization.data(withJSONObject: fields), session: session, request: request,
                operation: "terminalUI")
        }
        #expect(throws: HostWorkerError.rejected) {
            try HostTerminalUIEvent(
                presentationID: request.presentationID, sequence: 0, active: false, key: false,
                visible: false
            ).encoded(presentationID: request.presentationID)
        }
    }

    @Test func currentPackageRendererAndActualOwnerBirthArePinnedBeforeAndAfter() async throws {
        for change in [
            "version", "ownerPID", "ownerBirth", "rendererPID", "rendererBirth", "rendererHash",
            "session", "presentation", "inactive",
        ] {
            let fixture = try SceneFixture()
            let client = try HostTerminalSceneClient(
                current: { try fixture.current() },
                update: { _ in
                    fixture.updates += 1; fixture.change(change); return true
                },
                status: {
                    HostTerminalUIStatus(
                        presentationID: fixture.request.presentationID, focused: false)
                })
            await #expect(throws: HostWorkerError.rejected) {
                try await client.update(fixture.event(1))
            }
            #expect(fixture.updates == 1)
            await #expect(throws: HostWorkerError.rejected) { try await client.status() }
        }
        let fixture = try SceneFixture()
        let client = try HostTerminalSceneClient(
            current: { try fixture.current() },
            update: { _ in
                fixture.updates += 1; return true
            },
            status: {
                fixture.change("ownerBirth");
                return .init(presentationID: fixture.request.presentationID, focused: true)
            })
        await #expect(throws: HostWorkerError.rejected) { try await client.status() }
        #expect(fixture.updates == 0)
    }

    @Test func monotonicEventsDoNotReplayAfterFailureAndInactiveOrCancelledNeverSend() async throws
    {
        let fixture = try SceneFixture()
        let client = try HostTerminalSceneClient(
            current: { try fixture.current() },
            update: { _ in
                fixture.updates += 1; return false
            }, status: { .init(presentationID: fixture.request.presentationID, focused: false) })
        #expect(try await client.update(fixture.event(1)) == false)
        await #expect(throws: HostWorkerError.rejected) {
            try await client.update(fixture.event(1))
        }
        #expect(fixture.updates == 1)
        #expect(try await client.update(fixture.event(2)) == false)
        fixture.available = false
        await #expect(throws: HostWorkerError.rejected) {
            try await client.update(fixture.event(3))
        }
        #expect(fixture.updates == 2)
        fixture.available = true
        let task = Task {
            try Task.checkCancellation(); return try await client.update(fixture.event(3))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.updates == 2)
    }

    @Test func wrongOwnerUnconfiguredSceneAndForgedStatusCannotBecomeHealthy() async throws {
        let fixture = try SceneFixture()
        fixture.request = HostExtensionContentRequest(extensionID: "music", location: "main")
        #expect(throws: HostWorkerError.rejected) {
            try HostTerminalSceneClient(
                current: { try fixture.current() }, update: { _ in true },
                status: { .init(presentationID: UUID(), focused: true) })
        }
        fixture.request = try scene("herdr", "main")
        let client = try HostTerminalSceneClient(
            current: { try fixture.current() }, update: { _ in true },
            status: { .init(presentationID: UUID(), focused: true) })
        await #expect(throws: HostWorkerError.invalidResponse) { try await client.status() }
    }

    private func scene(_ owner: String, _ location: String) throws -> HostExtensionContentRequest {
        try terminalScene(owner, location)
    }
}

private func terminalScene(_ owner: String, _ location: String) throws
    -> HostExtensionContentRequest
{
    var target: HostHerdrWindowTarget?
    if location.hasPrefix("herdr.") {
        target = try HostHerdrWindowTarget.decode(
            JSONSerialization.data(withJSONObject: [
                "version": 1, "owner": "herdr", "location": location,
                "target": "synthetic-host.synthetic-agent",
                "token": UUID().uuidString, "title": "Synthetic", "width": 900, "height": 600,
                "minimumWidth": 400, "minimumHeight": 300, "presented": true,
            ]))
    }
    return .init(extensionID: owner, location: location, section: owner, herdrWindow: target)
}

@MainActor private final class SceneFixture {
    var request: HostExtensionContentRequest
    var version = "1.0.0"
    var session = UUID()
    var enginePID: Int32 = 42; var engineBirth = "synthetic-engine:1"
    var rendererPID: Int32 = 84; var rendererBirth = "synthetic-renderer:1"
    var hash = Data([1, 2, 3])
    var available = true
    var updates = 0
    init() throws { request = try terminalScene("herdr", "main") }
    func current() throws -> HostTerminalSceneIdentity {
        guard available else { throw HostWorkerError.rejected }
        return .init(
            request: request,
            package: ExtensionPackage(
                id: "herdr", version: version, hostABI: HostContract.compatibility,
                downloadURL: URL(
                    string: "https://github.com/synthetic/fixture/releases/download/1/herdr.zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1),
            session: session,
            engine: .init(
                pid: enginePID, generation: engineBirth,
                executable: URL(fileURLWithPath: "/tmp/synthetic-engine")),
            renderer: .init(
                pid: rendererPID, generation: rendererBirth,
                executable: URL(fileURLWithPath: "/tmp/synthetic-renderer"), codeHash: hash))
    }
    func event(_ sequence: UInt64) -> HostTerminalUIEvent {
        .init(
            presentationID: request.presentationID, sequence: sequence, active: false, key: false,
            visible: false)
    }
    func change(_ value: String) {
        switch value {
        case "version": version = "2.0.0"
        case "ownerPID": enginePID += 1
        case "ownerBirth": engineBirth = "synthetic-engine:2"
        case "rendererPID": rendererPID += 1
        case "rendererBirth": rendererBirth = "synthetic-renderer:2"
        case "rendererHash": hash = Data([4])
        case "session": session = UUID()
        case "presentation":
            request = HostExtensionContentRequest(extensionID: "herdr", location: "main")
        default: available = false
        }
    }
}
