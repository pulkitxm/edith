import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI
import Foundation

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: SystemStatsStatusItem?

    private var presentation: ControlPresentation?

    private var follow = SystemStatsFollow()

    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command.hasPrefix("systemStats.follow.") {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                return try await self.follow.execute(command, payload: payload)
            }
            if command == "systemStats.cli.catalog" {
                return try SystemStatsCLIExecution.catalog(payload)
            }
            if command.hasPrefix("systemStats.cli.stream.") {
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
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                let reply = try await SystemStatsCLIExecution.run(request)
                return try JSONEncoder().encode(reply)
            }
            if command.hasPrefix("systemStats.ui.") {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                let defaults = SharedDefaults.store
                switch command {
                case "systemStats.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "systemStats.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)

                case "systemStats.ui.action":
                    _ = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    throw ExtensionPeerError.invalidRequest
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults,
                    state: ControlPresentationState(
                        cpu: self.service?.snapshot.cpu ?? 0,
                        memory: self.service?.snapshot.memory ?? 0))
            }
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "systemStats", command: command, payload: payload,
                snapshot: { _ in
                    SystemStatsSurface.snapshot(
                        cpu: service.snapshot.cpu, memory: service.snapshot.memory,
                        freeDiskBytes: try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                            .volumeAvailableCapacityForImportantUsageKey
                        ]).volumeAvailableCapacityForImportantUsage)
                },
                perform: { action in
                    throw ExtensionPeerError.invalidRequest
                })
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            await cliStreams?.stopAndWait()
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
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "systemStats",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            presentation?.stop()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            presentation?.stop()
            presentation = nil
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            cliStreams?.stop()
            return ["ok": true] as NSDictionary
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
            else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if service == nil { service = SystemStatsStatusItem() }
            if cliStreams == nil { cliStreams = try? ExtensionCLIStreams(owner: "systemStats") }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
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
        case "synchronize": break
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            cliStreams?.stop()
            cliStreams = nil
            follow.shutdown()
            presentation?.stop()
            presentation = nil
            commands.shutdown()
            service?.shutdown()
            service = nil
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
