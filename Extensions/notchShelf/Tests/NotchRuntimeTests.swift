import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchRuntimeTests {
    @Test func startIdleThenAuthenticatedAttachCreatesOnlyPanelSuppressedOwnerAndReplaysReply()
        async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        var created: [NotchShelfController] = []
        let runtime = ExtensionRuntime(
            contextSource: { fixture.context },
            connectedDisplays: { [42: CGSize(width: 1280, height: 900)] },
            createController: { context, displays in
                let controller = NotchShelfController(
                    context: context, startsServices: false,
                    root: fixture.root.appendingPathComponent("Shelf"), hostDisplays: displays,
                    bluetoothPrivacyRequired: { false })
                created.append(controller)
                return controller
            })
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        _ = runtime.execute(["operation": "start", "defaultsSuite": suite])
        #expect(created.isEmpty)
        let initial = runtime.execute(["operation": "status"]) as? NSDictionary
        #expect(initial?["running"] as? Bool == false)
        let request = NotchPanelAttach(
            ownershipID: fixture.ownership, version: "1",
            displays: [
                .init(
                    displayID: 42, presentationID: fixture.presentation, width: 1280, height: 900,
                    collapsedWidth: 150, collapsedHeight: 28, isBuiltin: true)
            ])
        let reply = try JSONDecoder().decode(
            NotchPanelBatch.self, from: await invoke(runtime, "notch.panel.attach", request))
        try #require(created.count == 1)
        let owner = try #require(created.first)
        #expect(owner.ownedPanelCount == 0)
        let replay = try JSONDecoder().decode(
            NotchPanelBatch.self, from: await invoke(runtime, "notch.panel.attach", request))
        #expect(reply.identity == replay.identity)
        #expect(created.count == 1)
        try fixture.publish([:])
        let cleanupReplay = try JSONDecoder().decode(
            NotchPanelBatch.self, from: await invoke(runtime, "notch.panel.attach", request))
        #expect(cleanupReplay.identity == reply.identity)
        _ = try await invoke(runtime, "notch.panel.detach", reply.identity)
        _ = try await invoke(runtime, "notch.panel.detach", reply.identity)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(!owner.isRunning)
        #expect(owner.ownedPanelCount == 0)
    }

    private func invoke<T: Encodable>(_ runtime: ExtensionRuntime, _ command: String, _ request: T)
        async throws -> Data
    {
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(["token": UUID().uuidString, "command": command, "payload": payload]) {
                data, error in
                if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(
                        throwing: ExtensionPeerError.rejected(error as String? ?? "No reply"))
                }
            }
        }
    }
}
