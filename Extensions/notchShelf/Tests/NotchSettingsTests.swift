import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchSettingsTests {
    @Test func checkedFacadeSavesPreferencesAndRejectsForeignKeysAndStoppedEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let model = NotchSettingsModel { operation, payload in
            try await fixture.controller.execute(operation, payload: payload)
        }
        await model.refresh()
        #expect(model.snapshot.activeIDs == ["notchShelf"])
        #expect(model.snapshot.preferences[AppStorageKeys.Notch.shelfOpenOnHover] == "1")
        model.set(AppStorageKeys.Notch.shelfOpenOnHover, value: "0")
        await settle(model)
        #expect(
            fixture.defaults.object(forKey: AppStorageKeys.Notch.shelfOpenOnHover) as? Bool == false
        )
        #expect(model.snapshot.preferences[AppStorageKeys.Notch.shelfOpenOnHover] == "0")
        model.set(AppStorageKeys.Notch.shelfKeepDuration, value: "oneWeek")
        await settle(model)
        #expect(
            fixture.defaults.string(forKey: AppStorageKeys.Notch.shelfKeepDuration) == "oneWeek")
        for request in [
            NotchPreferenceRequest(key: "arbitrary.host.preference", value: "1"),
            NotchPreferenceRequest(key: AppStorageKeys.Notch.shelfKeepDuration, value: "invalid"),
            NotchPreferenceRequest(key: AppStorageKeys.Notch.shelfOpenOnHover, value: "yes"),
        ] {
            await #expect(throws: (any Error).self) {
                _ = try await fixture.controller.execute(
                    "notch.settings.write", payload: JSONEncoder().encode(request))
            }
        }
        #expect(fixture.defaults.object(forKey: "arbitrary.host.preference") == nil)
        fixture.controller.shutdown()
        await #expect(throws: (any Error).self) {
            _ = try await fixture.controller.execute(
                "notch.settings.read", payload: Data("{}".utf8))
        }
    }

    @Test func realEngineClientFacadeInvokesOwnedControllerAndRejectsDisabledEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let presentationID = UUID()
        let bridge = SettingsEngineBridge(
            controller: fixture.controller, presentationID: presentationID)
        let client = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: presentationID))
        let model = NotchSettingsModel(client: client)
        await model.refresh()
        #expect(model.snapshot.activeIDs == ["notchShelf"])
        model.set(AppStorageKeys.Notch.shelfRequireOption, value: "1")
        await settle(model)
        #expect(fixture.defaults.bool(forKey: AppStorageKeys.Notch.shelfRequireOption))
        #expect(bridge.operations == ["notch.settings.read", "notch.settings.write"])
        fixture.controller.shutdown()
        await model.refresh()
        #expect(model.error != nil)
        model.stop()
        client.invalidate()
        #expect(!model.available)
        await #expect(throws: (any Error).self) {
            _ = try await client.invoke("notch.settings.read")
        }
    }

    @Test func malformedSnapshotsNeverReachTheSettingsView() async throws {
        var snapshot = NotchSettingsSnapshot.empty
        snapshot.preferences["arbitrary"] = "1"
        let bytes = try JSONEncoder().encode(snapshot)
        let model = NotchSettingsModel { _, _ in bytes }
        await model.refresh()
        #expect(model.snapshot == .empty)
        #expect(model.error != nil)
        let disabled = NotchSettingsModel(client: nil)
        await disabled.refresh()
        #expect(!disabled.available)
        #expect(!disabled.busy)

    }

    @Test func newerActionAndStopDiscardLateRefreshesAndCancelLocalActions() async throws {
        let gate = Gate()
        let model = NotchSettingsModel { operation, _ in
            if operation == "notch.settings.read" { return await gate.hold() }
            var snapshot = NotchSettingsSnapshot.empty
            snapshot.preferences[AppStorageKeys.Notch.shelfOpenOnHover] = "0"
            return try JSONEncoder().encode(snapshot)
        }
        let refresh = Task { await model.refresh() }
        while gate.continuation == nil { await Task.yield() }
        model.set(AppStorageKeys.Notch.shelfOpenOnHover, value: "0")
        await settle(model)
        gate.release(try JSONEncoder().encode(NotchSettingsSnapshot.empty))
        await refresh.value
        #expect(model.snapshot.preferences[AppStorageKeys.Notch.shelfOpenOnHover] == "0")
        let stoppedGate = Gate()
        let stopped = NotchSettingsModel { _, _ in await stoppedGate.hold() }
        stopped.perform("notch.customize")
        while stoppedGate.continuation == nil { await Task.yield() }
        stopped.stop()
        stoppedGate.release(try JSONEncoder().encode(NotchSettingsSnapshot.empty))
        await Task.yield()
        #expect(!stopped.available)
        #expect(!stopped.busy)
        #expect(stopped.error == nil)
        #expect(stopped.snapshot == .empty)
    }

    @Test func customizationPreservesSavedUnavailableTilesAndUsesOwnedRequestChannel() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.controller.layouts.update(.notch) {
            $0.tiles = [SurfaceTile(.music), SurfaceTile(.clocks)]
            $0.hiddenTabs = ["camera"]
        }
        let model = NotchSettingsModel { operation, payload in
            try await fixture.controller.execute(operation, payload: payload)
        }
        model.perform("notch.customize")
        await settle(model)
        #expect(
            fixture.controller.context.sharedState.values(for: "notchShelf")["surface.openEditor"]
                == "notch")
        #expect(fixture.controller.layouts.notch.tiles.map(\.widget) == [.music, .clocks])
        #expect(fixture.controller.visibleSurfaceLayout.tiles.map(\.widget) == [.clocks])
        #expect(fixture.controller.layouts.notch.hiddenTabs == ["camera"])
    }

    private func settle(_ model: NotchSettingsModel) async {
        while model.busy { await Task.yield() }
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Data, Never>?
        func hold() async -> Data { await withCheckedContinuation { continuation = $0 } }
        func release(_ data: Data) { continuation?.resume(returning: data); continuation = nil }
    }

    @MainActor private struct Fixture {
        let id = "notch-settings-fixture-" + UUID().uuidString
        let root: URL
        let defaults: UserDefaults
        let controller: NotchShelfController
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
            defaults = try #require(UserDefaults(suiteName: id))
            defaults.set(false, forKey: AppStorageKeys.Notch.alertsEnabled)
            defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
            let state = ExtensionSharedState(root: root, namespace: id, owner: "host")
            try state.publish([
                "surface.activeIDs": "[\"notchShelf\"]",
                "surface.activeVersions": "{\"notchShelf\":\"1\"}",
            ])
            controller = NotchShelfController(
                context: .init(defaults: defaults, sharedState: state), startsServices: false,
                root: root.appendingPathComponent("Shelf"))
        }
        func clean() {
            controller.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor private final class SettingsEngineBridge: NSObject {
    let controller: NotchShelfController
    let presentationID: UUID
    private let commands = ExtensionCommandRegistry()
    private(set) var operations: [String] = []

    init(controller: NotchShelfController, presentationID: UUID) {
        self.controller = controller
        self.presentationID = presentationID
    }

    @objc func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data),
            request.presentationID == presentationID, (try? request.validate()) != nil
        else { return }
        operations.append(request.operation)
        commands.invoke([
            "token": request.token.uuidString, "command": request.operation,
            "payload": request.payload,
        ]) { data, error in
            let reply = ExtensionEngineReply(
                token: request.token, ok: error == nil, payload: (data as Data?) ?? Data())
            if let bytes = try? ExtensionEngineWire.encode(reply) { completion(bytes as NSData) }
        } execute: { [controller] operation, payload in
            try await controller.execute(operation, payload: payload)
        }
    }

    @objc func cancel(_ token: NSString) { commands.cancel(token as String) }
}
