import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrHostWindowNavigationTests {
    @Test func actualEngineDescriptorIsUnpresentedUntilExactHostAdmission() async throws {
        defer { HerdrWorkOwnership.enable() }
        let bridge = SyntheticHerdrNavigationBridge()
        let navigation = try #require(HerdrHostWindowNavigationClient(bridge: bridge))
        let store = HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] })
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
            sshTarget: nil, session: "fixture", pane: "one", kind: "Synthetic tool",
            status: .working, title: "Synthetic agent", workspace: "Synthetic space",
            cwd: "/tmp/fixture")
        store.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [agent])
        ]
        let worker = HerdrWorker(
            hostWindowNavigation: navigation, store: store,
            defaults: HerdrUIDefaults(), automaticActions: false)
        let facade = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let original = try JSONDecoder().decode(
            HerdrUIPresentation.self,
            from: await facade.perform(
                "herdr.ui.present", object: ["kind": "agent", "id": agent.id]))
        #expect(!original.presented)
        let origin = UUID()
        bridge.open = { input, completion in
            #expect(input["presentationID"] as? String == origin.uuidString)
            let bytes = try #require(input["descriptor"] as? Data)
            let retained = try JSONDecoder().decode(HerdrUIPresentation.self, from: bytes)
            #expect(retained == original && !retained.presented)
            try worker.spaces.admit(retained.token)
            completion(nil)
        }
        let admitted = try JSONDecoder().decode(
            HerdrUIPresentation.self,
            from: await facade.perform(
                "herdr.ui.presentation.open",
                object: [
                    "presentationID": origin.uuidString, "token": original.token.uuidString,
                ]))
        #expect(admitted.presented && admitted.token == original.token)
        #expect(admitted.matches(location: "herdr.agent", target: agent.id, token: original.token))
        #expect(
            admitted.matches(
                location: "herdr.agent.controls", target: agent.id, token: original.token))
        #expect(!admitted.matches(location: "herdr.space", target: agent.id, token: original.token))
        #expect(!admitted.matches(location: "herdr.agent", target: agent.id, token: UUID()))
        try worker.spaces.focus(original.token, key: true)
        _ = try await facade.perform(
            "herdr.ui.presentation.close", object: ["token": original.token.uuidString])
        #expect(throws: ExtensionPeerError.self) {
            try worker.spaces.focus(original.token, key: true)
        }
        await worker.shutdown()
    }

    @Test func cancelledRequestsCancelOnlyReturnedHostTokenAndRejectLateCompletion() async throws {
        let bridge = SyntheticHerdrNavigationBridge()
        let client = try #require(HerdrHostWindowNavigationClient(bridge: bridge))
        var callback: ((NSString?) -> Void)?
        bridge.open = { _, completion in callback = completion }
        let descriptor = HerdrUIPresentation(
            version: 1, owner: "herdr", location: "herdr.agent",
            target: "synthetic", token: UUID(), title: "Synthetic", width: 1000, height: 640,
            minimumWidth: 560, minimumHeight: 360, presented: false)
        let task = Task { try await client.open(descriptor, presentationID: UUID()) }
        while callback == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bridge.cancelled == [bridge.token])
        callback?(nil)
        await Task.yield()
        client.invalidate()
        #expect(bridge.cancelled == [bridge.token])
        await #expect(throws: ExtensionPeerError.self) {
            try await client.open(descriptor, presentationID: UUID())
        }
    }

    @Test func trustedOptionalMachineAliasesPreserveExactAndAmbiguousSelectors() async throws {
        defer { MachineRegistry.shutdown() }
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "machines": [
                [
                    "id": id.uuidString, "name": "Synthetic saved host",
                    "sshTarget": "synthetic@host.invalid",
                    "aliases": ["original-build-alias"],
                ]
            ]
        ])
        try await MachineRegistry.refresh { operation, payload, _ in
            #expect(operation == "machines.companion.hosts" && payload == Data("{}".utf8))
            return bytes
        }
        #expect(try MachineResolver.machine("ORIGINAL-BUILD-ALIAS").id == id)
        #expect(try MachineResolver.machine("original-build").id == id)
        let other = Machine(name: "Other", host: "other.invalid", aliases: ["original-build-alias"])
        #expect(throws: CLIFailure.self) {
            try MachineResolver.machine(
                "original-build-alias", in: MachineRegistry.machines() + [other])
        }
        let malformed = try JSONSerialization.data(withJSONObject: [
            "machines": [
                [
                    "id": id.uuidString, "name": "Synthetic", "sshTarget": "host.invalid",
                    "aliases": ["*"],
                ]
            ]
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await MachineRegistry.refresh { _, _, _ in malformed }
        }
        #expect(MachineRegistry.machines().first?.aliases == ["original-build-alias"])
    }
}

@MainActor private final class SyntheticHerdrNavigationBridge: NSObject {
    let token = UUID().uuidString
    var cancelled: [String] = []
    var open: (NSDictionary, @escaping (NSString?) -> Void) throws -> Void = { _, completion in
        completion(nil)
    }
    @objc(openHerdrWindow:completion:)
    func openWindow(_ input: NSDictionary, completion: @escaping (NSString?) -> Void) -> NSString {
        do { try open(input, completion) } catch {
            completion(error.localizedDescription as NSString)
        }
        return token as NSString
    }
    @objc(cancelNavigation:) func cancelNavigation(_ input: NSString) {
        cancelled.append(input as String)
    }
}
