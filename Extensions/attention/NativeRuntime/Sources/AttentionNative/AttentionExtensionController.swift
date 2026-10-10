@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import AppKit
import Foundation
import SwiftUI

@MainActor
@objc(EdithAttentionExtensionController)
public final class AttentionExtensionController: NSObject {
    private let bundle: Bundle
    private var database: AttentionDatabase?
    private var uiClient: AttentionUIClient?
    private var uiModel: AttentionPageModel?
    private(set) var trackingSettings: AttentionTrackingSettingsModel?
    private var uiPresentationID: UUID?
    private var uiLocation: String?
    private var uiSection: String?
    private var uiConfigured = false
    private var service: AttentionBackgroundService?
    private var favicon: FaviconService?
    private var surface: AttentionSurface?
    private var repository: AttentionRepository?
    private var startup: Task<Void, Never>?
    private var stopped = false
    private var stoppingTask: Task<Void, Never>?
    private var activeCalls = 0
    private let commands = ExtensionCommandRegistry()

    public init(bundle: Bundle) {
        self.bundle = bundle
        super.init()
    }

    @objc public func invoke(
        _ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void
    ) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, !self.stopped, let service = self.service else {
                throw ExtensionPeerError.unavailable
            }
            self.activeCalls += 1
            defer { self.activeCalls -= 1 }
            await self.startup?.value
            try Task.checkCancellation()
            if command.hasPrefix("attention.ui.") {
                guard let repository = self.repository else { throw ExtensionPeerError.unavailable }
                return try await AttentionUICommands.execute(
                    command, payload: payload, repository: repository, service: service)
            }
            if command == "cli.execute" {
                guard let repository = self.repository else { throw ExtensionPeerError.unavailable }
                return try AttentionPayload.encode(
                    try await AttentionCLIExecution.run(
                        AttentionPayload.decode(ExtensionCLIRequest.self, from: payload),
                        repository: repository, service: service))
            }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            if command == AgentFaviconClient.operation {
                guard payload.count <= 16_384, let favicon = self.favicon else {
                    throw ExtensionPeerError.invalidRequest
                }
                let url = try AttentionPayload.decode(URL.self, from: payload)
                return try AttentionPayload.encode(try await favicon.data(for: url))
            }
            return try await AttentionCommands.execute(command, payload: payload, service: service)
        }
    }

    @objc(prepareToStopWithCompletion:)
    public func prepareToStop(completion: @escaping () -> Void) {
        stopUI()
        if let stoppingTask {
            Task {
                await stoppingTask.value; completion()
            }
            return
        }
        stopped = true
        commands.shutdown()
        startup?.cancel()
        let service = service
        let favicon = favicon
        let startup = startup
        let task = Task {
            await startup?.value
            await service?.stop()
            await favicon?.stop()
            while self.activeCalls > 0 { await Task.yield() }
            try? self.database?.close()
            self.database = nil
            self.repository = nil
        }
        stoppingTask = task
        Task {
            await task.value; completion()
        }
    }

    @objc(prepareDisableWithCompletion:)
    public func prepareDisable(completion: @escaping (NSError?) -> Void) {
        prepareToStop { completion(nil) }
    }

    @objc public func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return [
                "id": "attention", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "attention"
            else {
                return ["ok": false] as NSDictionary
            }
            guard !configuration.uiOnly, let engine = configuration.engineClient,
                configurePresentation(input, engine: engine)
            else { return ["ok": false] as NSDictionary }
        case "stopUI":
            guard input["presentationID"] as? String == uiPresentationID?.uuidString else {
                return ["ok": false] as NSDictionary
            }
            stopUI()
        case "start":
            guard !uiConfigured, Bundle.main.bundleURL.pathExtension != "appex" else {
                return ["ok": false] as NSDictionary
            }
            guard !stopped, let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard service == nil else { return ["ok": true] as NSDictionary }
            do {
                AttentionResources.directory = bundle.resourceURL
                let database = try AttentionDatabase(
                    url: AttentionPaths.root.appendingPathComponent("attention-history.sqlite"))
                self.database = database
                let fixture =
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
                let service = AttentionBackgroundService(
                    store: database,
                    cloudDirectory: fixture
                        ? AttentionPaths.root.appendingPathComponent("fixture-cloud")
                        : AttentionCloudStorage.directory,
                    cloudAvailable: { !fixture && AttentionCloudStorage.available },
                    collectsSystemActivity: !fixture)
                self.service = service
                let repository = AttentionRepository(
                    eventSink: AttentionEventStore(store: database))
                self.repository = repository
                favicon = FaviconService(allowsNetwork: !fixture)
                if fixture, try !AttentionEventStore(store: database).hasEvents() {
                    try repository.append(
                        AttentionEvent(
                            id: "fixture-editor", startedAt: Date().addingTimeInterval(-120),
                            duration: 60, source: .application, appName: "Fixture Editor",
                            bundleID: "com.example.fixture.editor"))
                }
                surface = AttentionSurface(repository: repository, service: service)
                startup = Task { await service.start() }
            } catch { return ["ok": false, "message": error.localizedDescription] as NSDictionary }
        case "view":
            guard !stopped, let uiClient, !uiClient.stopped,
                input["presentationID"] as? String == uiPresentationID?.uuidString,
                input["location"] as? String == uiLocation,
                input["section"] as? String == uiSection
            else {
                return ["ok": false] as NSDictionary
            }
            if let trackingSettings {
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        AttentionTrackingSettings(model: trackingSettings)
                    })
            }
            guard let model = uiModel else {
                return ["ok": false] as NSDictionary
            }
            if input["location"] as? String == "home" {
                guard input["section"] as? String == "focus",
                    let data = input["tile"] as? Data, data.count <= 65_536,
                    let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                    tile.widget == .focus
                else { return ["ok": false] as NSDictionary }
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        AttentionHomeFocusCard(
                            tile: tile, repository: .init(root: URL(fileURLWithPath: "/unused")),
                            uiClient: uiClient
                        ) { _ in
                            ExtensionPresentation.showWindow()
                        }
                    })
            }
            return NSHostingController(rootView: ExtensionPageHost { AttentionPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !stopped else { return ["ok": false] as NSDictionary }
            IPC.post(IPC.Name.settingsChanged)
        case "stop":
            stopUI()
            if !stopped { prepareToStop(completion: {}) }
            surface = nil; service = nil; favicon = nil; startup = nil
        case "status": return ["ok": true, "running": !stopped && service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    func configurePresentation(_ input: NSDictionary, engine: ExtensionEngineClient) -> Bool {
        guard !stopped, input["extensionID"] as? String == "attention",
            input["uiOnly"] as? Bool == false,
            input["presentationID"] as? String == engine.presentationID.uuidString,
            let location = input["location"] as? String,
            let section = input["section"] as? String,
            (location == "settings" && section == "extension")
                || (location == "main" && section == "attention")
                || (location == "home" && section == "focus")
        else { return false }
        guard location != "settings" || (input["tile"] == nil && input["target"] == nil) else {
            return false
        }
        stopUI()
        let client = AttentionUIClient(engine: engine)
        uiClient = client
        uiPresentationID = engine.presentationID
        uiLocation = location
        uiSection = section
        if location == "settings" {
            trackingSettings = AttentionTrackingSettingsModel(client: client)
        } else {
            uiModel = AttentionPageModel(
                repository: .init(root: URL(fileURLWithPath: "/unused")), uiClient: client)
        }
        uiConfigured = true
        return true
    }

    private func stopUI() {
        trackingSettings?.stop(); trackingSettings = nil
        uiPresentationID = nil; uiLocation = nil; uiSection = nil
        uiClient?.stop(); uiClient = nil
        uiModel?.cancelLoading()
        let model = uiModel
        uiModel = nil
        Task { await model?.shutdown() }
    }

}

enum AttentionResources {
    nonisolated(unsafe) static var directory: URL?
    static var chromeExtension: URL? {
        if let directory {
            return Bundle(
                url: directory.appendingPathComponent("AttentionNative_AttentionNative.bundle"))?
                .url(forResource: "ChromeExtension", withExtension: nil)
        }
        return Bundle.module.url(forResource: "ChromeExtension", withExtension: nil)
    }
}
