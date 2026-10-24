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
final class ExtensionRuntime: NSObject {
    private var service: SystemStatsStatusItem?
    private let uiConfiguration: @MainActor (NSDictionary) -> ExtensionUIConfiguration?
    private let uiDefaults: UserDefaults

    init(
        uiConfiguration: @escaping @MainActor (NSDictionary) -> ExtensionUIConfiguration? = {
            ExtensionUIConfiguration(context: $0)
        },
        uiDefaults: UserDefaults = SharedDefaults.store
    ) {
        self.uiConfiguration = uiConfiguration
        self.uiDefaults = uiDefaults
        super.init()
    }

    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var draining = false
    private var settingsDetail = false

    private var follow = SystemStatsFollow()

    private var fixture: WorkerFixtureAdmission?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            return try await self.withFixtureRequest(
                command, payload: payload, token: request["token"] as? String
            ) { [weak self] in
                if command.hasPrefix("systemStats.follow.") {
                    guard self?.fixture == nil else { throw ExtensionPeerError.unavailable }
                    guard let self, self.service != nil else {
                        throw ExtensionPeerError.unavailable
                    }
                    return try await self.follow.execute(command, payload: payload)
                }
                if command == "systemStats.cli.catalog" {
                    return try SystemStatsCLIExecution.catalog(payload)
                }
                if command.hasPrefix("systemStats.cli.stream.") {
                    guard self?.fixture == nil else { throw ExtensionPeerError.unavailable }
                    guard let self, self.service != nil, let streams = self.cliStreams else {
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
                    guard let self, self.service != nil else {
                        throw ExtensionPeerError.unavailable
                    }
                    guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
                    let reply = try await SystemStatsCLIExecution.run(request)
                    return try JSONEncoder().encode(reply)
                }
                if command.hasPrefix("systemStats.ui.") {
                    guard let self, self.service != nil else {
                        throw ExtensionPeerError.unavailable
                    }
                    return try ControlPresentationContract.execute(
                        command, payload: payload, defaults: SharedDefaults.store,
                        state: ControlPresentationState(
                            cpu: self.service?.snapshot.cpu ?? 0,
                            memory: self.service?.snapshot.memory ?? 0))
                }
                guard let self, let service = self.service else {
                    throw ExtensionPeerError.unavailable
                }
                return try await SurfaceCommandService.execute(
                    providerID: "systemStats", command: command, payload: payload,
                    snapshot: { _ in
                        let volume = Self.dataVolume()
                        return SystemStatsSurface.snapshot(
                            cpu: service.snapshot.cpu, memory: service.snapshot.memory,
                            freeDiskBytes: self.fixture != nil ? 1_000_000 : volume?.free,
                            totalDiskBytes: self.fixture != nil ? 4_000_000 : volume?.total)
                    },
                    perform: { action in
                        throw ExtensionPeerError.invalidRequest
                    })
            }
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        _ = commands.suspend()
        draining = true
        let presentation = presentation
        presentation?.stop()
        let service = service, streams = cliStreams, follow = follow
        streams?.stop()
        follow.shutdown()
        service?.suspendWork()
        Task { [self, service, streams, follow, presentation] in
            _ = await commands.suspendAndWait()
            await streams?.stopAndWait()
            await follow.shutdownAndWait()
            await service?.suspendAndWait()
            await finishPresentations(presentation)
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        draining = true
        retirePresentation()
        let service = service, streams = cliStreams, follow = follow
        commands.shutdown()
        streams?.stop()
        follow.shutdown()
        service?.suspendWork()
        Task { [self, service, streams, follow] in
            await commands.shutdownAndWait()
            await streams?.stopAndWait()
            await follow.shutdownAndWait()
            await service?.suspendAndWait()
            await finishPresentations(nil)
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "systemStats", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !draining, presentationStops.isEmpty else { return ["ok": false] as NSDictionary }
            guard let configuration = uiConfiguration(input),
                configuration.extensionID == "systemStats",
                configuration.defaultsSuite
                    == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard
                SystemStatsSettingsScene.accepts(input)
                    || (!configuration.uiOnly && input["location"] as? String == "main"
                        && input["section"] as? String == "systemStats")
            else { return ["ok": false] as NSDictionary }
            retirePresentation()
            settingsDetail = SystemStatsSettingsScene.accepts(input)
            presentation = ControlPresentation(
                client: configuration.engineClient, defaults: uiDefaults)
            return ["ok": true] as NSDictionary
        case "stopUI":
            retirePresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            cliStreams?.stop()
            return ["ok": true] as NSDictionary
        case "start":
            guard !draining else { return ["ok": false] as NSDictionary }
            do {
                guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                    input["hostedFunctionalFixture"] == nil
                else { throw WorkerFixtureError.invalid }
                fixture = try WorkerFixtureAdmission.current(
                    extensionID: "systemStats", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                return startOwned(input)
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            if settingsDetail {
                return SystemStatsSettingsScene.controller(
                    presentation: presentation, defaults: uiDefaults)
            }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("System Stats")
                        } content: {
                            Form {
                                Section("Usage") {
                                    if presentation.active {
                                        SystemMenuReadings(
                                            cpu: presentation.state.cpu,
                                            memory: presentation.state.memory)
                                    } else {
                                        Text("Enable System Stats to see live readings.")
                                            .settingsCaption()
                                    }
                                }
                                Section("Menu Bar") {
                                    Text(
                                        "CPU and memory readings refresh every two seconds while this extension is enabled."
                                    )
                                    .settingsCaption()
                                }
                            }.formStyle(.grouped)
                        }
                    }
                })
        case "synchronize":
            guard !draining else { return ["ok": false] as NSDictionary }
            break
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            cliStreams?.stop()
            cliStreams = nil
            follow.shutdown()
            retirePresentation()
            commands.shutdown()
            service?.shutdown()
            service = nil
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
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

    private func startOwned(_ input: NSDictionary) -> NSObject {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
        else { return ["ok": false] as NSDictionary }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return ["ok": false] as NSDictionary }
        if service == nil { service = SystemStatsStatusItem(fixture: fixture) }
        if cliStreams == nil { cliStreams = try? ExtensionCLIStreams(owner: "systemStats") }
        return ["ok": true] as NSDictionary
    }

    private func withFixtureRequest(
        _ operation: String, payload: Data, token: String?,
        execute: () async throws -> Data
    ) async throws -> Data {
        return try await execute()
    }

    private func retirePresentation() {
        guard let presentation else { return }
        presentation.stop()
        let id = UUID()
        presentationStops[id] = Task { [self, presentation] in
            defer { presentationStops[id] = nil }
            await presentation.stopAndWait()
        }
        self.presentation = nil
    }

    private func finishPresentations(_ presentation: ControlPresentation?) async {
        await presentation?.stopAndWait()
        while !presentationStops.isEmpty {
            let pending = Array(presentationStops.values)
            for task in pending { await task.value }
        }
    }

}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
