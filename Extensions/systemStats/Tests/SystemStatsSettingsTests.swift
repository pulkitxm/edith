import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import SystemStatsExtension
@testable import EdithExtensionSupport

@MainActor
private final class SettingsFixtureBridge: NSObject {
    let defaults: UserDefaults
    var operations: [String] = []
    var cancelled: [String] = []
    var delayed: (ExtensionEngineRequest, (NSData) -> Void)?
    var delay = false

    init(defaults: UserDefaults) { self.defaults = defaults }

    @objc(invoke:completion:)
    func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
            try request.validate()
            operations.append(request.operation)
            if delay { delayed = (request, completion); return }
            let payload = try ControlPresentationContract.execute(
                request.operation, payload: request.payload, defaults: defaults,
                state: ControlPresentationState(cpu: 12, memory: 34))
            completion(
                try ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                    as NSData)
        } catch {
            let request = try! ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
            completion(
                try! ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: false)) as NSData)
        }
    }

    @objc(cancel:) func cancel(_ token: NSString) { cancelled.append(token as String) }
}

@MainActor @Suite(.serialized)
struct SystemStatsSettingsTests {
    private func fixture() -> UserDefaults {
        UserDefaults(suiteName: "edith.systemStats.settings.fixture." + UUID().uuidString)!
    }

    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }

    @Test func originalColorBindingsRoundTripThroughCurrentClientAndEngineContract() async throws {
        let engine = fixture()
        let local = fixture()
        engine.set("auto", forKey: AppStorageKeys.MenuBar.statsColorMode)
        engine.set("FFFFFF", forKey: AppStorageKeys.MenuBar.statsColorHex)
        let bridge = SettingsFixtureBridge(defaults: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = ControlPresentation(client: client, defaults: local)
        defer { model.stop() }
        await model.refresh()
        #expect(model.ready)
        #expect(model.state.cpu == 12)
        let rows = SystemStatsRows(presentation: model, defaults: local)
        #expect(rows.modeBinding.wrappedValue == "auto")
        rows.modeBinding.wrappedValue = "custom"
        rows.colorBinding.wrappedValue = Color(
            red: 18.0 / 255, green: 171.0 / 255, blue: 52.0 / 255)
        try await settle {
            engine.string(forKey: AppStorageKeys.MenuBar.statsColorMode) == "custom"
                && engine.string(forKey: AppStorageKeys.MenuBar.statsColorHex) == "12AB34"
        }
        let preference = SystemStatsColorPreference(defaults: engine)
        #expect(preference.mode == .custom)
        let tint = try #require(preference.tint.usingColorSpace(.sRGB))
        #expect(abs(tint.redComponent - 18.0 / 255) < 0.001)
        #expect(abs(tint.greenComponent - 171.0 / 255) < 0.001)
        #expect(abs(tint.blueComponent - 52.0 / 255) < 0.001)
        rows.modeBinding.wrappedValue = "auto"
        try await settle { engine.string(forKey: AppStorageKeys.MenuBar.statsColorMode) == "auto" }
        #expect(SystemStatsColorPreference(defaults: engine).tint == .labelColor)
        #expect(Set(bridge.operations) == ["systemStats.ui.read", "systemStats.ui.update"])
        #expect(engine.string(forKey: AppStorageKeys.MenuBar.statsColorHex) == "12AB34")
    }

    @Test func invalidColorWritesRejectWholeBatchAndForeignOperations() throws {
        let defaults = fixture()
        defaults.set("auto", forKey: AppStorageKeys.MenuBar.statsColorMode)
        defaults.set("FFFFFF", forKey: AppStorageKeys.MenuBar.statsColorHex)
        for value: Any in [
            "", "#FFFFFF", "GGGGGG", "12345", "1234567", true, 123456, ["hex": "123456"],
        ] {
            let payload = try JSONEncoder().encode(
                ControlPreferenceUpdate(
                    values: ControlPresentationContract.encode([
                        AppStorageKeys.MenuBar.statsColorMode: "custom",
                        AppStorageKeys.MenuBar.statsColorHex: value,
                    ]), removed: []))
            #expect(throws: (any Error).self) {
                try ControlPresentationContract.execute(
                    "systemStats.ui.update", payload: payload, defaults: defaults,
                    state: ControlPresentationState())
            }
            #expect(defaults.string(forKey: AppStorageKeys.MenuBar.statsColorMode) == "auto")
            #expect(defaults.string(forKey: AppStorageKeys.MenuBar.statsColorHex) == "FFFFFF")
        }
        #expect(
            !ControlPresentationContract.valid(
                "unknown", for: AppStorageKeys.MenuBar.statsColorMode))
        for operation in ["systemStats.ui.action", "system.ui.update", "host.navigate"] {
            #expect(throws: (any Error).self) {
                try ControlPresentationContract.execute(
                    operation, payload: Data("{}".utf8), defaults: defaults,
                    state: ControlPresentationState())
            }
        }
        #expect(throws: (any Error).self) {
            try ControlPresentationContract.execute(
                "systemStats.ui.read", payload: Data("{\"foreign\":true}".utf8), defaults: defaults,
                state: ControlPresentationState())
        }
    }

    @Test func disableCancelsActualClientAndLateResponseCannotChangeSettings() async throws {
        let engine = fixture()
        let local = fixture()
        engine.set("auto", forKey: AppStorageKeys.MenuBar.statsColorMode)
        let bridge = SettingsFixtureBridge(defaults: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = ControlPresentation(client: client, defaults: local)
        await model.refresh()
        bridge.delay = true
        let read = Task { await model.refresh() }
        try await settle { bridge.delayed != nil }
        let (request, completion) = try #require(bridge.delayed)
        model.stop()
        await read.value
        try await settle { bridge.cancelled.contains(request.token.uuidString) }
        engine.set("custom", forKey: AppStorageKeys.MenuBar.statsColorMode)
        completion(
            try ExtensionEngineWire.encode(
                ExtensionEngineReply(
                    token: request.token, ok: true,
                    payload: ControlPresentationContract.snapshot(
                        defaults: engine, state: ControlPresentationState()))) as NSData)
        await Task.yield()
        let rows = SystemStatsRows(presentation: model, defaults: local)
        rows.modeBinding.wrappedValue = "custom"
        #expect(local.string(forKey: AppStorageKeys.MenuBar.statsColorMode) == "auto")
        #expect(!model.running)
        #expect(bridge.operations.count == 2)
    }

    @Test func disabledOriginalRowsCannotWriteOrStartEngine() {
        let defaults = fixture()
        let model = ControlPresentation(client: nil, defaults: defaults)
        defer { model.stop() }
        let rows = SystemStatsRows(presentation: model, defaults: defaults)
        rows.modeBinding.wrappedValue = "custom"
        rows.colorBinding.wrappedValue = .red
        #expect(defaults.object(forKey: AppStorageKeys.MenuBar.statsColorMode) == nil)
        #expect(defaults.object(forKey: AppStorageKeys.MenuBar.statsColorHex) == nil)
        #expect(model.ready && !model.active)
    }

    @Test func exactDetailSceneOwnsNeverVisibleOriginalController() async throws {
        _ = NSApplication.shared
        let defaults = fixture()
        let model = ControlPresentation(client: nil, defaults: defaults) { operation, payload in
            try ControlPresentationContract.execute(
                operation, payload: payload, defaults: defaults,
                state: ControlPresentationState())
        }
        defer { model.stop() }
        await model.refresh()
        #expect(SystemStatsSettingsScene.accepts(["location": "settings", "section": "extension"]))
        #expect(
            !SystemStatsSettingsScene.accepts(["location": "settings", "section": "systemStats"]))
        #expect(!SystemStatsSettingsScene.accepts(["location": "main", "section": "extension"]))
        let controller = SystemStatsSettingsScene.controller(
            presentation: model, defaults: defaults)
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.window == nil)
        #expect(!controller.view.subviews.isEmpty)
    }
    #if SYSTEM_STATS_NATIVE_RUNTIME
    @Test func checkedRuntimeConfigureAndOriginalViewFactoryRejectForeignAndStoppedRequests() throws
    {
        _ = NSApplication.shared
        let host = "edith.settings.factory." + UUID().uuidString
        let suite = host + ".extension.systemStats.worker"
        let previous = ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        setenv("EDITH_SHARED_DEFAULTS_SUITE", suite, 1)
        defer {
            if let previous {
                setenv("EDITH_SHARED_DEFAULTS_SUITE", previous, 1)
            } else {
                unsetenv("EDITH_SHARED_DEFAULTS_SUITE")
            }
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = ExtensionRuntime(
            uiConfiguration: {
                ExtensionUIConfiguration(
                    context: $0, hostIdentifier: host,
                    extensionID: "systemStats", defaultsSuite: suite)
            }, uiDefaults: defaults)
        #expect((runtime.execute(["operation": "view"]) as? NSDictionary)?["ok"] as? Bool == false)
        let context: NSDictionary = [
            "operation": "configureUI", "remoteUI": true, "hostIdentifier": host,
            "extensionID": "systemStats", "defaultsSuite": suite, "uiOnly": true,
            "presentationID": UUID().uuidString, "location": "settings", "section": "extension",
        ]
        #expect((runtime.execute(context) as? NSDictionary)?["ok"] as? Bool == true)
        let controller = try #require(runtime.execute(["operation": "view"]) as? NSViewController)
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.window == nil && !controller.view.subviews.isEmpty)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        for (key, value) in [
            ("extensionID", "foreign"), ("defaultsSuite", "foreign"), ("section", "foreign"),
            ("location", "main"),
        ] {
            let rejected = context.mutableCopy() as! NSMutableDictionary
            rejected[key] = value
            #expect((runtime.execute(rejected) as? NSDictionary)?["ok"] as? Bool == false)
        }
        _ = runtime.execute(["operation": "stopUI"])
        #expect((runtime.execute(["operation": "view"]) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(
            (runtime.execute(["operation": "status"]) as? NSDictionary)?["running"] as? Bool
                == false)
        let untrusted = ExtensionRuntime(uiDefaults: defaults)
        #expect((untrusted.execute(context) as? NSDictionary)?["ok"] as? Bool == false)
    }
    #endif

}
