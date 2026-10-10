import AppKit
import EdithExtensionUI
import EdithStudio
import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import EdithExtensionSupport
@testable import StudioExtension

@MainActor private final class StudioSettingsEngineProbe: NSObject {
    struct Pending {
        let request: ExtensionEngineRequest
        let completion: (NSData) -> Void
    }

    let engine: StudioModel
    var requests: [ExtensionEngineRequest] = []
    var pending: [Pending] = []
    var cancellations: Set<UUID> = []
    var delayed = false

    init(engine: StudioModel) { self.engine = engine }

    @objc(invoke:completion:)
    func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: bytes as Data)
            requests.append(request)
            let pending = Pending(request: request, completion: completion)
            if delayed { self.pending.append(pending) } else { deliver(pending) }
        } catch { Issue.record(error) }
    }

    func deliver(_ pending: Pending, payload: Data? = nil) {
        Task {
            do {
                let data: Data
                if let payload {
                    data = payload
                } else {
                    data = try await StudioUICommands.execute(
                        pending.request.operation, payload: pending.request.payload, model: engine)
                }
                let reply = ExtensionEngineReply(
                    token: pending.request.token, ok: true, payload: data)
                pending.completion(try ExtensionEngineWire.encode(reply) as NSData)
            } catch {
                let reply = ExtensionEngineReply(token: pending.request.token, ok: false)
                pending.completion(try! ExtensionEngineWire.encode(reply) as NSData)
            }
        }
    }

    @objc func cancel(_ value: NSString) {
        if let token = UUID(uuidString: value as String) { cancellations.insert(token) }
    }
}

@MainActor private final class StudioSettingsNavigationProbe: NSObject {
    let token = UUID()
    var input: NSDictionary?
    var completion: ((NSString?) -> Void)?
    var cancelled = false

    @objc(navigate:completion:)
    func navigate(_ input: NSDictionary, completion: @escaping (NSString?) -> Void) -> NSString? {
        self.input = input
        self.completion = completion
        return token.uuidString as NSString
    }

    @objc func cancelNavigation(_ value: NSString) {
        cancelled = value as String == token.uuidString
    }
}

@MainActor @Suite(.serialized) struct StudioSettingsTests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    private func defaults() throws -> (String, UserDefaults) {
        let suite = "studio.settings.synthetic.\(UUID().uuidString)"
        return (suite, try #require(UserDefaults(suiteName: suite)))
    }

    @Test func originalPickerRoundTripsEveryDestinationWithoutMediaReadsAndPersistsAfterDisable()
        async throws
    {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved synthetic library", forKey: AppStorageKeys.Studio.library)
        let engine = StudioModel(defaults: defaults, loadsState: false)
        let probe = StudioSettingsEngineProbe(engine: engine)
        let id = UUID()
        let client = try #require(ExtensionEngineClient(bridge: probe, presentationID: id))
        let facade = StudioUIFacade(client: client, settingsOnly: true)
        let remote = StudioModel(defaults: defaults, loadsState: false, facade: facade)
        defer { remote.shutdown(); engine.shutdown() }
        facade.refresh()
        try await waitUntil { facade.state != nil }
        var picker = StudioDestinationPicker(model: remote, chooseFolder: { nil })
        for mode in StudioDestinationMode.allCases {
            try picker.inspect().find(ViewType.Picker.self).select(value: mode.rawValue)
            try await waitUntil {
                defaults.string(forKey: AppStorageKeys.Studio.destination) == mode.rawValue
                    && facade.state?.destinationMode == mode.rawValue
            }
        }
        try picker.inspect().find(button: "Choose folder…").tap()
        #expect(remote.destinationFolder.isEmpty)
        picker.chooseFolder = {
            URL(fileURLWithPath: "/synthetic/studio/output", isDirectory: true)
        }
        try picker.inspect().find(button: "Choose folder…").tap()
        try await waitUntil { facade.state?.destinationFolder == "/synthetic/studio/output" }
        #expect(
            remote.destination
                == .folder(URL(fileURLWithPath: "/synthetic/studio/output", isDirectory: true)))
        #expect(
            probe.requests.allSatisfy {
                $0.presentationID == id
                    && ["studio.ui.settings", "studio.ui.settings.preferences"].contains(
                        $0.operation)
            })
        #expect(remote.files.isEmpty && engine.files.isEmpty && engine.jobs.isEmpty)
        remote.shutdown()
        picker.mode.wrappedValue = "downloads"
        #expect(defaults.string(forKey: AppStorageKeys.Studio.destination) == "folder")
        let replacement = StudioModel(defaults: defaults, loadsState: false)
        defer { replacement.shutdown() }
        #expect(replacement.destination == remote.destination)
        #expect(
            defaults.string(forKey: AppStorageKeys.Studio.library) == "preserved synthetic library")
        let read = try await StudioUICommands.execute(
            "studio.ui.settings", payload: Data("{}".utf8), model: replacement)
        #expect(
            try JSONDecoder().decode(StudioUIState.self, from: read).destinationFolder
                == "/synthetic/studio/output")
    }

    @Test func currentClientCancelsStaleReadsWritesAndDisableRejectsLateReplies() async throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        defer { engine.shutdown() }
        let probe = StudioSettingsEngineProbe(engine: engine)
        probe.delayed = true
        let client = try #require(ExtensionEngineClient(bridge: probe, presentationID: UUID()))
        let facade = StudioUIFacade(client: client, settingsOnly: true)
        let remote = StudioModel(defaults: defaults, loadsState: false, facade: facade)
        facade.refresh()
        try await waitUntil { probe.pending.count == 1 }
        remote.setDestination(mode: "folder", folder: "/synthetic/old")
        try await waitUntil { probe.pending.count == 2 }
        remote.setDestination(mode: "downloads", folder: "/synthetic/latest")
        try await waitUntil { probe.pending.count == 3 && probe.cancellations.count == 2 }
        probe.deliver(probe.pending[2])
        try await waitUntil { facade.state?.destinationMode == "downloads" }
        var stale = try JSONDecoder().decode(
            StudioUIState.self,
            from: await StudioUICommands.execute(
                "studio.ui.settings", payload: Data("{}".utf8), model: engine))
        stale.destinationMode = "original"
        let bytes = try JSONEncoder().encode(stale)
        probe.deliver(probe.pending[0], payload: bytes)
        probe.deliver(probe.pending[1], payload: bytes)
        await Task.yield()
        #expect(
            remote.destinationMode == "downloads" && remote.destinationFolder == "/synthetic/latest"
        )
        facade.refresh()
        try await waitUntil { probe.pending.count == 4 }
        remote.shutdown()
        try await waitUntil { probe.cancellations.contains(probe.pending[3].request.token) }
        probe.deliver(probe.pending[3], payload: bytes)
        await Task.yield()
        #expect(facade.isStopped && remote.destinationMode == "downloads" && remote.message == nil)
        await #expect(throws: ExtensionEngineError.self) {
            try await client.invoke("studio.ui.settings")
        }
        engine.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await StudioUICommands.execute(
                "studio.ui.settings.preferences",
                payload: Data("{\"mode\":\"original\",\"folder\":\"\"}".utf8), model: engine)
        }
        #expect(defaults.string(forKey: AppStorageKeys.Studio.destination) == "downloads")
    }

    @Test func settingsEngineRejectsInvalidFieldsModesFoldersAndCancellationBeforeWrite()
        async throws
    {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        defer { engine.shutdown() }
        for object in [
            ["mode": "invalid", "folder": ""],
            ["mode": "folder", "folder": "relative/path"],
            ["mode": "folder", "folder": "https://example.invalid/output"],
            ["mode": "folder", "folder": "/synthetic", "unknown": "value"],
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            await #expect(throws: (any Error).self) {
                try await StudioUICommands.execute(
                    "studio.ui.settings.preferences", payload: bytes, model: engine)
            }
        }
        var ready: CheckedContinuation<Void, Never>?
        let task = Task {
            await withCheckedContinuation { ready = $0 }
            return try await StudioUICommands.execute(
                "studio.ui.settings.preferences",
                payload: Data("{\"mode\":\"downloads\",\"folder\":\"\"}".utf8), model: engine)
        }
        try await waitUntil { ready != nil }
        task.cancel()
        ready?.resume()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(defaults.object(forKey: AppStorageKeys.Studio.destination) == nil)
    }

    @Test func actualRuntimeFactoriesAdmitOnlyExactActiveRoutesAndReleaseOnlyCurrentScene()
        async throws
    {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        defer { engine.shutdown() }
        let probe = StudioSettingsEngineProbe(engine: engine)
        let configuredSuite = try #require(
            ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let suffix = ".extension.studio.worker"
        try #require(configuredSuite.hasSuffix(suffix))
        let host = String(configuredSuite.dropLast(suffix.count))
        let runtime = ExtensionRuntime(uiConfiguration: {
            ExtensionUIConfiguration(
                context: $0, hostIdentifier: host, extensionID: "studio",
                defaultsSuite: configuredSuite)
        })
        defer { _ = runtime.execute(["operation": "stopUI"]) }
        let id = UUID()
        let input: NSDictionary = [
            "operation": "configureUI", "remoteUI": true, "hostIdentifier": host,
            "extensionID": "studio", "defaultsSuite": configuredSuite, "uiOnly": false,
            "presentationID": id.uuidString, "engineClient": probe,
            "location": "settings", "section": "extension",
        ]
        #expect((runtime.execute(input) as? NSDictionary)?["ok"] as? Bool == true)
        let view = input.mutableCopy() as! NSMutableDictionary
        view["operation"] = "view"
        #expect(
            runtime.execute(view) is NSHostingController<ExtensionPageHost<StudioSettingsScene>>)
        for (key, value) in [
            ("location", "main"), ("section", "studio"), ("presentationID", UUID().uuidString),
        ] {
            let invalid = view.mutableCopy() as! NSMutableDictionary
            invalid[key] = value
            #expect((runtime.execute(invalid) as? NSDictionary)?["ok"] as? Bool == false)
        }
        for (key, value) in [
            ("location", "home"), ("section", "other"), ("defaultsSuite", "foreign"),
            ("extensionID", "other"),
        ] {
            let invalid = input.mutableCopy() as! NSMutableDictionary
            invalid[key] = value
            #expect((runtime.execute(invalid) as? NSDictionary)?["ok"] as? Bool == false)
        }
        let disabled = input.mutableCopy() as! NSMutableDictionary
        disabled["uiOnly"] = true; disabled.removeObject(forKey: "engineClient")
        #expect((runtime.execute(disabled) as? NSDictionary)?["ok"] as? Bool == false)
        let main = input.mutableCopy() as! NSMutableDictionary
        let mainID = UUID()
        main["presentationID"] = mainID.uuidString; main["location"] = "main";
        main["section"] = "studio"
        #expect((runtime.execute(main) as? NSDictionary)?["ok"] as? Bool == true)
        main["operation"] = "view"
        #expect(runtime.execute(main) is NSViewController)
        #expect(
            (runtime.execute(["operation": "stopUI", "presentationID": id.uuidString])
                as? NSDictionary)?["ok"] as? Bool == true)
        #expect((runtime.execute(view) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(runtime.execute(main) is NSViewController)
        #expect(probe.requests.isEmpty && engine.files.isEmpty)
    }

    @Test func openStudioUsesScopedExistingWindowNavigationAndCancelsOnRelease() async throws {
        let probe = StudioSettingsNavigationProbe()
        let navigation = try #require(StudioSettingsNavigation(bridge: probe))
        let id = UUID()
        let payload = try JSONSerialization.data(withJSONObject: ["presentationID": id.uuidString])
        let task = Task { try await navigation.execute(payload) }
        try await waitUntil { probe.input != nil }
        #expect(probe.input?["section"] as? String == "studio")
        #expect(probe.input?["location"] as? String == "settings")
        #expect(probe.input?["presentationID"] as? String == id.uuidString)
        probe.completion?(nil)
        #expect(try await task.value == Data("{}".utf8))
        let cancelled = Task { try await navigation.execute(payload) }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(probe.cancelled)
        probe.completion?(nil)
        navigation.invalidate()
        await #expect(throws: ExtensionPeerError.self) { _ = try await navigation.execute(payload) }
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await navigation.execute(Data("{\"presentationID\":\"invalid\"}".utf8))
        }
    }

    @Test func originalSettingsFormLaysOutNeverVisibleAtBothWidthsZoomAndColorSchemes() async throws
    {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        defer { engine.shutdown() }
        let facade = StudioUIFacade(
            settingsOnly: true,
            invoke: { operation, payload in
                try await StudioUICommands.execute(operation, payload: payload, model: engine)
            })
        let model = StudioModel(defaults: defaults, loadsState: false, facade: facade)
        defer { model.shutdown() }
        facade.refresh()
        try await waitUntil { facade.state != nil }
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for width in [420.0, 900.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    model.destinationMode = "folder"
                    model.destinationFolder = "/synthetic/output"
                    let hosting = NSHostingView(
                        rootView: StudioSettingsScene(model: model)
                            .environment(\.colorScheme, scheme)
                            .environment(\.compactLayout, width == 420)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.windowVisible, false))
                    hosting.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    hosting.layoutSubtreeIfNeeded()
                    #expect(hosting.window == nil && !hosting.subviews.isEmpty)
                    let controls = try StudioSettingsScene(model: model).inspect()
                    #expect(
                        try controls.find(ViewType.Picker.self).labelView().text().string()
                            == "Save results")
                    #expect(try controls.find(button: "Open Studio").isDisabled() == false)
                    #expect(try controls.find(button: "output").isDisabled() == false)
                    #expect(
                        hosting.fittingSize.width.isFinite && hosting.fittingSize.height.isFinite)
                }
            }
        }
        #expect(facade.state != nil && model.files.isEmpty)
    }
}
