import EdithExtensionSupport
import Foundation
import Testing

@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrHostFolderChoiceTests {
    @Test func originalSettingsControlUsesSealedOriginAndValidatedHostResult() async throws {
        defer { HerdrWorkOwnership.enable() }
        let bridge = SyntheticHerdrFolderBridge()
        let chooser = try #require(HerdrHostFolderChoiceClient(bridge: bridge))
        let worker = HerdrWorker(
            hostFolderChoice: chooser,
            store: HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] }),
            defaults: HerdrUIDefaults(), automaticActions: false)
        let monitor = AgentActivityMonitor(
            defaults: HerdrUIDefaults(),
            uiClient: HerdrUIClient { try await worker.execute($0, payload: $1) })
        let origin = UUID()
        monitor.folderPresentationID = origin
        bridge.choose = { input, completion in
            #expect(input.count == 1 && input["presentationID"] as? String == origin.uuidString)
            completion(["selectedPath": "/tmp/synthetic-project"], nil)
        }
        #expect(try await monitor.chooseProjectFolder()?.path == "/tmp/synthetic-project")
        bridge.choose = { _, completion in completion(["cancelled": true], nil) }
        #expect(try await monitor.chooseProjectFolder() == nil)
        monitor.folderPresentationID = nil
        await #expect(throws: ExtensionPeerError.self) { try await monitor.chooseProjectFolder() }
        await monitor.shutdown()
        chooser.invalidate()
    }

    @Test func localHideCancelsExactHostTokenAndRejectsLateResult() async throws {
        let bridge = SyntheticHerdrFolderBridge()
        let chooser = try #require(HerdrHostFolderChoiceClient(bridge: bridge))
        let origin = UUID()
        var late: ((NSDictionary?, NSString?) -> Void)?
        bridge.choose = { _, completion in late = completion }
        let monitor = AgentActivityMonitor(
            defaults: HerdrUIDefaults(),
            uiClient: HerdrUIClient { _, payload in
                let object = try JSONSerialization.jsonObject(with: payload) as! [String: String]
                #expect(object == ["presentationID": origin.uuidString])
                let path = try await chooser.choose(presentationID: origin)
                return try JSONSerialization.data(
                    withJSONObject: path.map { ["selectedPath": $0] } ?? ["cancelled": true])
            })
        monitor.folderPresentationID = origin
        let request = Task { try await monitor.chooseProjectFolder() }
        while late == nil { await Task.yield() }
        monitor.cancelFolderChoice()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(bridge.cancelled == [bridge.token])
        late?(["selectedPath": "/tmp/late-project"], nil)
        chooser.invalidate()
        await monitor.shutdown()
        #expect(bridge.cancelled == [bridge.token])
    }

    @Test func malformedResultAndInvalidationNeverReturnAnArbitraryPath() async throws {
        for value: NSDictionary in [
            [:], ["selectedPath": "relative"], ["selectedPath": "/tmp/../project"],
            ["selectedPath": "/tmp/project", "cancelled": true], ["cancelled": false],
            ["selectedPath": "/tmp/\0project"],
        ] {
            #expect(throws: ExtensionPeerError.self) { try HerdrHostFolderChoiceClient.path(value) }
        }
        let bridge = SyntheticHerdrFolderBridge()
        let chooser = try #require(HerdrHostFolderChoiceClient(bridge: bridge))
        bridge.choose = { _, completion in completion(["selectedPath": "/tmp/../project"], nil) }
        await #expect(throws: ExtensionPeerError.self) {
            try await chooser.choose(presentationID: UUID())
        }
        #expect(bridge.cancelled == [bridge.token])
        chooser.invalidate()
        await #expect(throws: ExtensionPeerError.self) {
            try await chooser.choose(presentationID: UUID())
        }
    }
}

@MainActor private final class SyntheticHerdrFolderBridge: NSObject {
    let token = UUID().uuidString
    var cancelled: [String] = []
    var choose: (NSDictionary, @escaping (NSDictionary?, NSString?) -> Void) -> Void = {
        _, completion in completion(["cancelled": true], nil)
    }
    @objc(chooseFolder:completion:)
    func chooseFolder(
        _ input: NSDictionary, completion: @escaping (NSDictionary?, NSString?) -> Void
    ) -> NSString {
        choose(input, completion)
        return token as NSString
    }
    @objc(cancelNavigation:) func cancelNavigation(_ token: NSString) {
        cancelled.append(token as String)
    }
}
