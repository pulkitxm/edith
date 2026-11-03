internal import EdithExtensionCommands
import EdithExtensionCore
internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import AppKit
import CoreFoundation
import Foundation
import SwiftUI
internal import WorkerFixtureSupport

@MainActor
final class AttentionService: NSObject, ExtensionService {
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
    private var uiShutdownTasks: [UUID: Task<Void, Never>] = [:]
    @MainActor
    private final class Storage {
        fileprivate let ambientPolicy: ExtensionAmbientPolicy
        fileprivate let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?

        init(
            ambientPolicy: ExtensionAmbientPolicy,
            admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?
        ) {
            self.ambientPolicy = ambientPolicy
            self.admitFixture = admitFixture
        }
    }

    private let storage: Storage
    private var ambientPolicy: ExtensionAmbientPolicy { storage.ambientPolicy }
    private var admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission? {
        storage.admitFixture
    }

    private let notifySettingsChanged: () -> Void

    convenience init(bundle: Bundle) {
        self.init(
            bundle: bundle, notifySettingsChanged: { IPC.post(IPC.Name.settingsChanged) },
            admitFixture: {
                try WorkerFixtureAdmission.current(
                    extensionID: "attention", context: $0, roleBundle: bundle)
            })
    }

    init(
        bundle: Bundle, notifySettingsChanged: @escaping () -> Void,
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "attention", context: $0, roleBundle: .main)
        }, ambientPolicy: ExtensionAmbientPolicy? = nil
    ) {
        self.notifySettingsChanged = notifySettingsChanged
        storage = Storage(
            ambientPolicy: ambientPolicy
                ?? ExtensionAmbientPolicy(jobs: [
                    "attention.ingest": ExtensionAmbientCadence(ambient: 900, live: 900)
                ]),
            admitFixture: admitFixture)
        self.bundle = bundle
        super.init()
    }

    var isRunning: Bool { !stopped && service != nil }
    var preparesForDisable: Bool { true }
    var allowsUIDuringRetirement: Bool { true }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !stopped, let service else {
            throw ExtensionPeerError.unavailable
        }
        await self.startup?.value
        try Task.checkCancellation()
        if command.hasPrefix("attention.ui.") {
            guard let repository = self.repository else { throw ExtensionPeerError.unavailable }
            return try await AttentionUICommands.execute(
                command, payload: payload, repository: repository, service: service)
        }
        if command == "attention.cli.catalog" {
            return try ExtensionCLICatalog.data(
                AttentionCommand.self, owner: "attention", payload: payload, streaming: false)
        }
        if command == "cli.execute" || command == "attention.cli" {
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

    func cancelPendingWork() {
        startup?.cancel()
    }

    func drain() async {
        await startup?.value
        await service?.cancelPendingWorkAndWait()
        await favicon?.cancelPendingWorkAndWait()
        startup = nil
    }

    func prepareDisable() async throws {
        await finishBeforeStop()
        await drain()
        await teardown()
    }

    func finishBeforeStop() async {
        _ = stopUI()
        stopped = true
        startup?.cancel()
    }

    func teardown() async {
        await startup?.value
        await service?.stop()
        await favicon?.stop()
        for task in Array(uiShutdownTasks.values) { await task.value }
        try? database?.close()
        database = nil
        repository = nil
        surface = nil
        service = nil
        favicon = nil
        startup = nil
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        let input = configuration.input
        guard !configuration.uiOnly, let engine = configuration.engineClient else { return false }
        return configurePresentation(input, engine: engine)
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !uiConfigured, !ExtensionHostRole.isInterfaceProcess else {
            return false
        }
        guard !stopped, let suite = input["defaultsSuite"] as? String,
            suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        do {
            let admission = try admitFixture(input)
            guard service == nil else { return true }
            try ambientPolicy.apply(context: input)
            if let admission { AttentionPaths.root = admission.dataDirectory }
            AttentionResources.directory = bundle.resourceURL
            let database = try AttentionDatabase(
                url: AttentionPaths.root.appendingPathComponent("attention-history.sqlite"))
            self.database = database
            let fixture = admission != nil
            let service = AttentionBackgroundService(
                store: database,
                cloudDirectory: fixture
                    ? AttentionPaths.root.appendingPathComponent("fixture-cloud")
                    : AttentionCloudStorage.directory,
                cloudAvailable: { !fixture && AttentionCloudStorage.available },
                collectsSystemActivity: !fixture, ambientPolicy: ambientPolicy)
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
            if !fixture {
                let root = AttentionPaths.root
                startup = Task {
                    _ = try? AttentionLegacyHistoryImport.run(
                        source: root.appendingPathComponent(
                            AttentionLegacyHistoryImport.sourceName),
                        marker: root.appendingPathComponent(
                            AttentionLegacyHistoryImport.markerName),
                        into: database)
                    _ = AttentionExtensionInstaller.refreshIfOutdated()
                    await service.start()
                }
            }
        } catch { return false }
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        let input = context.input
        guard !stopped, let uiClient, !uiClient.stopped,
            input["presentationID"] as? String == uiPresentationID?.uuidString,
            input["location"] as? String == uiLocation,
            input["section"] as? String == uiSection
        else {
            return nil
        }
        if let trackingSettings {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    AttentionTrackingSettings(model: trackingSettings)
                })
        }
        guard let model = uiModel else {
            return nil
        }
        if input["location"] as? String == "home" {
            guard input["section"] as? String == "focus",
                let data = input["tile"] as? Data, data.count <= 65_536,
                let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                tile.widget == .focus
            else { return nil }
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
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !stopped else { return false }
        do {
            _ = try admitFixture(input)
            let policyOnly: Bool
            if let value = input["ambientPolicyOnly"] {
                guard let number = value as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID()
                else { throw ExtensionPeerError.invalidRequest }
                policyOnly = number.boolValue
            } else {
                policyOnly = false
            }
            try ambientPolicy.apply(context: input)
            if !policyOnly { notifySettingsChanged() }
        } catch {
            return false
        }
        return true
    }

    func acceptsStopUI(for presentation: UUID?) -> Bool {
        presentation == uiPresentationID
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
        _ = stopUI()
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

    func stopUI() -> [Task<Void, Never>] {
        trackingSettings?.stop(); trackingSettings = nil
        uiPresentationID = nil; uiLocation = nil; uiSection = nil
        uiClient?.stop(); uiClient = nil
        uiModel?.cancelLoading()
        let model = uiModel
        uiModel = nil
        guard let model else { return Array(uiShutdownTasks.values) }
        let token = UUID()
        uiShutdownTasks[token] = Task { [self, model] in
            await model.shutdown()
            uiShutdownTasks[token] = nil
        }
        return Array(uiShutdownTasks.values)
    }

}

@MainActor
public func makeAttentionRuntime(bundle: Bundle) -> ExtensionServiceRuntime {
    makeAttentionRuntime(bundle: bundle, service: AttentionService(bundle: bundle))
}

@MainActor
func makeAttentionRuntime(bundle: Bundle, service: AttentionService) -> ExtensionServiceRuntime {
    ExtensionServiceRuntime(id: "attention", role: "app", bundle: bundle) { _ in service }
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
