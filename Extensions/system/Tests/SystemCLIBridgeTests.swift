import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing
@testable import SystemExtension

@Suite(.serialized) @MainActor struct SystemCLIBridgeTests {
    @Test func originalListQuitPreviewAndConfirmedForceUseOwnedOperations() async throws {
        let app = RunningAppSnapshot(
            pid: 424242, name: "Synthetic Editor", bundleID: "synthetic.editor", active: true)
        var writes: [Bool] = []
        let center = RunningAppOperationCenter(
            snapshot: { [app] },
            perform: { plan, confirmed in
                writes.append(confirmed); return plan.count
            }, resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 128) })
        let list = try await SystemCLIExecution.run(
            .init(arguments: ["ls", "--json"]), operations: center)
        #expect(
            list.exitCode == 0 && list.stderr.isEmpty && list.stdout.contains("Synthetic Editor")
                && list.stdout.contains("128"))
        let preview = try await SystemCLIExecution.run(
            .init(arguments: ["quit", "synthetic.editor", "--json"]), operations: center)
        #expect(
            preview.exitCode == 0 && preview.stdout.contains("\"applied\": false") && writes.isEmpty
        )
        let result = try await SystemCLIExecution.run(
            .init(arguments: ["quit", "synthetic.editor", "--force", "--yes", "--json"]),
            operations: center)
        #expect(
            result.exitCode == 0 && result.stdout.contains("\"changed\": 1") && writes == [true])
        let missing = try await SystemCLIExecution.run(
            .init(arguments: ["quit", "missing", "--yes"]), operations: center)
        #expect(
            missing.exitCode == 3 && missing.stdout.isEmpty
                && missing.stderr.contains("no running app"))
        #expect(SystemCLIEnvironment.operations == nil)
    }
    @Test func remoteOriginalInventorySortAndPrivacyAreEngineOwned() async throws {
        let suite = "synthetic.system.ui." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = RunningAppOperationCenter(
            snapshot: {
                [
                    .init(
                        pid: 424242, name: "Synthetic Editor", bundleID: "synthetic.editor",
                        active: false)
                ]
            }, resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 64) })
        let owner = RunningAppsModel(operations: center, defaults: defaults)
        let presentation = SystemPresentationState(channel: nil); presentation.apply(hideApps: true)
        let bridge = Bridge(owner: owner, presentation: presentation, defaults: defaults)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remotePresentation = SystemPresentationState(channel: nil)
        let remote = RunningAppsModel(
            engineClient: client, presentation: remotePresentation, defaults: defaults)
        await remote.refresh()
        #expect(remote.apps.first?.name == "Synthetic Editor" && remotePresentation.hideApps)
        remote.sort(by: .name)
        for _ in 0..<1000 {
            if defaults.string(forKey: RunningAppsKeys.sort) == "name" { break }; await Task.yield()
        }
        #expect(defaults.string(forKey: RunningAppsKeys.sort) == "name")
        remote.shutdown(); client.invalidate(); owner.shutdown(); presentation.shutdown()
        await remote.refresh()
        #expect(!remote.loading.isRunning)
    }
    @MainActor private final class Bridge: NSObject {
        let owner: RunningAppsModel; let presentation: SystemPresentationState;
        let defaults: UserDefaults
        let registry = ExtensionCommandRegistry()
        init(owner: RunningAppsModel, presentation: SystemPresentationState, defaults: UserDefaults)
        { self.owner = owner; self.presentation = presentation; self.defaults = defaults }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            registry.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { bytes, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil && bytes != nil,
                                payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
                },
                execute: { [self] operation, payload in
                    if operation == "system.apps.snapshot" {
                        await owner.refresh();
                        return try JSONEncoder().encode(owner.snapshot(presentation: presentation))
                    }
                    guard operation == "system.apps.sort" else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    let sort = try JSONDecoder().decode(SystemAppsSort.self, from: payload)
                    defaults.set(sort.sortKey, forKey: RunningAppsKeys.sort);
                    defaults.set(sort.ascending, forKey: RunningAppsKeys.ascending);
                    owner.restoreSort(sort)
                    return Data("{}".utf8)
                })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
