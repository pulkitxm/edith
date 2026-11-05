#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI
import Foundation

@MainActor
final class SystemStatsService: ExtensionService {
    static let title = "Menu Bar Stats"
    private unowned let runtime: ExtensionServiceRuntime
    private var item: SystemStatsStatusItem?
    private let uiDefaults: UserDefaults
    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var draining = false
    private var settingsDetail = false
    private let follow = SystemStatsFollow()
    private var fixture: WorkerFixtureAdmission?
    private var cliStreams: ExtensionCLIStreams?

    init(runtime: ExtensionServiceRuntime, uiDefaults: UserDefaults = SharedDefaults.store) {
        self.runtime = runtime
        self.uiDefaults = uiDefaults
    }

    var isRunning: Bool { item != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        do {
            guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                !context.isHostedFunctionalFixture
            else { return false }
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "systemStats", context: context.input,
                roleBundle: Bundle(for: SystemStatsService.self))
        } catch { return false }
        guard !draining, !ExtensionHostRole.isInterfaceProcess, presentation == nil
        else { return false }
        if item == nil { item = SystemStatsStatusItem(fixture: fixture) }
        if cliStreams == nil { cliStreams = try? ExtensionCLIStreams(owner: "systemStats") }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool { !draining }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        operation == "prepareToStop" ? runtime.execute(["operation": "stop"]) : nil
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("systemStats.follow.") {
            guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
            guard self.item != nil else {
                throw ExtensionPeerError.unavailable
            }
            return try await self.follow.execute(command, payload: payload)
        }
        if command == "systemStats.cli.catalog" {
            return try SystemStatsCLIExecution.catalog(payload)
        }
        if command.hasPrefix("systemStats.cli.stream.") {
            guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
            guard self.item != nil, let streams = self.cliStreams else {
                throw ExtensionPeerError.unavailable
            }
            return try streams.invoke(
                SystemCommand.self, operation: command,
                prefix: "systemStats.cli.stream", payload: payload)
        }
        if command == "systemStats.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await SystemStatsCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            guard self.item != nil else {
                throw ExtensionPeerError.unavailable
            }
            guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
            let reply = try await SystemStatsCLIExecution.run(request)
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("systemStats.ui.") {
            guard self.item != nil else {
                throw ExtensionPeerError.unavailable
            }
            return try ControlPresentationContract.execute(
                command, payload: payload, defaults: SharedDefaults.store,
                state: ControlPresentationState(
                    cpu: self.item?.snapshot.cpu ?? 0,
                    memory: self.item?.snapshot.memory ?? 0))
        }
        guard let item = self.item else {
            throw ExtensionPeerError.unavailable
        }
        return try await SurfaceCommandService.execute(
            providerID: "systemStats", command: command, payload: payload,
            snapshot: { _ in
                let volume = Self.dataVolume()
                return SystemStatsSurface.snapshot(
                    cpu: item.snapshot.cpu, memory: item.snapshot.memory,
                    freeDiskBytes: self.fixture != nil ? 1_000_000 : volume?.free,
                    totalDiskBytes: self.fixture != nil ? 4_000_000 : volume?.total)
            },
            perform: { action in
                throw ExtensionPeerError.invalidRequest
            })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !draining, presentationStops.isEmpty,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        let settings = SystemStatsSettingsScene.accepts(configuration.input)
        guard
            settings
                || (!configuration.uiOnly && configuration.location == "main"
                    && configuration.section == "systemStats")
        else { return false }
        _ = retirePresentation()
        settingsDetail = settings
        presentation = ControlPresentation(client: configuration.engineClient, defaults: uiDefaults)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let presentation = self.presentation else { return nil }
        if settingsDetail {
            return SystemStatsSettingsScene.controller(
                presentation: presentation, defaults: uiDefaults)
        }
        let defaults = uiDefaults
        return NSHostingController(
            rootView: ExtensionPageHost {
                SystemStatsPage(presentation: presentation, defaults: defaults)
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        draining = true
        presentation?.stop()
        cliStreams?.stop()
        follow.shutdown()
        item?.suspendWork()
    }

    func drain() async {
        await cliStreams?.stopAndWait()
        await follow.shutdownAndWait()
        await item?.suspendAndWait()
        await presentation?.stopAndWait()
        await finishPresentations()
    }

    func teardown() async {
        cliStreams?.stop()
        cliStreams = nil
        follow.shutdown()
        _ = retirePresentation()
        item?.shutdown()
        item = nil
        await finishPresentations()
    }

    private static func dataVolume() -> (free: Int64, total: Int64)? {
        let url =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey,
            ]), let free = VolumeCapacity.availableBytes(in: values),
            let total = values.volumeTotalCapacity
        else { return nil }
        return (free, Int64(total))
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        let id = UUID()
        let task = Task { [self, presentation] in
            defer { presentationStops[id] = nil }
            await presentation.stopAndWait()
        }
        presentationStops[id] = task
        self.presentation = nil
        return task
    }

    private func finishPresentations() async {
        while let task = presentationStops.values.first { await task.value }
    }
}

@MainActor
func makeSystemStatsRuntime(uiDefaults: UserDefaults = SharedDefaults.store)
    -> ExtensionServiceRuntime
{
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "systemStats", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { SystemStatsService(runtime: $0, uiDefaults: uiDefaults) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeSystemStatsRuntime()).toOpaque())
        })
}
