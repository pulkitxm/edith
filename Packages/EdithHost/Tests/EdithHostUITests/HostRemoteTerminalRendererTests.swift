import AppKit
@preconcurrency import ExtensionKit
import Foundation
import Testing
import EdithHostCore

@testable import EdithHost

@Suite @MainActor struct HostRemoteTerminalRendererTests {
    @Test func neverVisibleControllersReuseOriginalManagedSceneInputOnlyForClosedLocations() throws
    {
        for (owner, location) in [
            ("terminal", "main"), ("herdr", "main"), ("herdr", "herdr.agent"),
            ("herdr", "herdr.space"), ("quinjet", "main"), ("herdr", "settings"), ("music", "main"),
        ] {
            var target: HostHerdrWindowTarget?
            if location.hasPrefix("herdr.") {
                target = try HostHerdrWindowTarget.decode(
                    JSONSerialization.data(withJSONObject: [
                        "version": 1, "owner": "herdr", "location": location,
                        "target": "synthetic-host.synthetic-agent",
                        "token": UUID().uuidString, "title": "Synthetic", "width": 900,
                        "height": 600,
                        "minimumWidth": 400, "minimumHeight": 300, "presented": true,
                    ]))
            }
            let request = HostExtensionContentRequest(
                extensionID: owner, location: location, section: owner, herdrWindow: target)
            var calls = 0
            let remote = EXHostViewController()
            #expect(remote.configuration == nil)
            let controller = HostRemoteViewController(
                request: request, remote: remote,
                terminalUI: .init(
                    update: { _ in
                        calls += 1; return true
                    },
                    status: {
                        calls += 1;
                        return .init(presentationID: request.presentationID, focused: false)
                    }),
                connect: { _, _, _ in calls += 1 }, update: { _ in calls += 1 })
            _ = controller.view
            #expect(controller.view.window == nil && !controller.connected)
            #expect((controller.terminalInput != nil) == HostTerminalUIRequest.accepts(request))
            #expect(!controller.consumeTerminalTabKey(characters: "t", modifiers: .command))
            controller.detach()
            #expect(controller.detached && calls == 0)
            #expect(remote.configuration == nil && controller.children.isEmpty)
        }
    }

    @Test func exactConfiguredClosedOwnerUsesOriginalFixedRendererWire() throws {
        for owner in ["terminal", "herdr", "quinjet"] {
            var renderer = HostRemoteTerminalRenderer()
            let request = HostExtensionContentRequest(extensionID: owner, location: "main")
            let session = UUID()
            var operations: [String] = []
            let event = HostTerminalUIEvent(
                presentationID: request.presentationID, sequence: 1, active: false, key: false,
                visible: false)
            let update = HostTerminalUIRequest(
                session: session, request: request, operation: .update, event: event)
            let data = try renderer.response(
                update, session: session, owner: owner, configuredRequest: request
            ) { operation, context in
                operations.append(operation)
                #expect(
                    Set(context.allKeys.compactMap { $0 as? String }) == [
                        "presentationID", "payload",
                    ])
                #expect(context["presentationID"] as? String == request.presentationID.uuidString)
                let payload = try #require(context["payload"] as? Data)
                #expect(try JSONDecoder().decode(HostTerminalUIEvent.self, from: payload) == event)
                return ["ok": true]
            }
            #expect(try JSONSerialization.jsonObject(with: data) as? [String: Bool] == ["ok": true])
            let status = HostTerminalUIRequest(
                session: session, request: request, operation: .status)
            _ = try renderer.response(
                status, session: session, owner: owner, configuredRequest: request
            ) { operation, context in
                operations.append(operation)
                #expect(context.count == 1)
                return [
                    "ok": true, "presentationID": request.presentationID.uuidString,
                    "focused": false,
                ]
            }
            #expect(operations == ["terminalUI", "terminalUIStatus"])
        }
    }

    @Test func staleUnconfiguredWrongOwnerReplayAndBadReplyAreRejected() throws {
        var renderer = HostRemoteTerminalRenderer()
        let request = HostExtensionContentRequest(extensionID: "herdr", location: "main")
        let session = UUID()
        let update = HostTerminalUIRequest(
            session: session, request: request, operation: .update,
            event: .init(
                presentationID: request.presentationID, sequence: 1, active: false, key: false,
                visible: false))
        var calls = 0
        for (expectedSession, owner, configured): (UUID, String, HostExtensionContentRequest?) in [
            (UUID(), "herdr", request), (session, "quinjet", request), (session, "herdr", nil),
            (session, "herdr", HostExtensionContentRequest(extensionID: "herdr", location: "main")),
        ] {
            #expect(throws: HostWorkerError.rejected) {
                try renderer.response(
                    update, session: expectedSession, owner: owner, configuredRequest: configured
                ) { _, _ in
                    calls += 1; return ["ok": true]
                }
            }
        }
        #expect(calls == 0)
        _ = try renderer.response(
            update, session: session, owner: "herdr", configuredRequest: request
        ) { _, _ in
            calls += 1; return ["ok": true]
        }
        #expect(throws: HostWorkerError.rejected) {
            try renderer.response(
                update, session: session, owner: "herdr", configuredRequest: request
            ) { _, _ in
                calls += 1; return ["ok": true]
            }
        }
        #expect(calls == 1)
        let status = HostTerminalUIRequest(session: session, request: request, operation: .status)
        for result: NSDictionary in [
            ["ok": true, "presentationID": UUID().uuidString, "focused": true],
            [
                "ok": true, "presentationID": request.presentationID.uuidString, "focused": true,
                "command": "start",
            ],
            ["ok": true, "padding": String(repeating: "x", count: 1025)],
        ] {
            #expect(throws: (any Error).self) {
                try renderer.response(
                    status, session: session, owner: "herdr", configuredRequest: request
                ) { _, _ in result }
            }
        }
    }
}
