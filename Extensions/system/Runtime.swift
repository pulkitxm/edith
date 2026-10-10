import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithSystemExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: RunningAppsModel?
    private var uiModel: RunningAppsModel?
    private var uiPresentation: SystemPresentationState?
    private var uiClient: ExtensionEngineClient?
    private var presentation: SystemPresentationState?
    private var cleaning: KeyboardCleaning?
    private let operations: RunningAppOperationCenter = {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
            return RunningAppOperationCenter()
        }
        return RunningAppOperationCenter(
            snapshot: {
                [
                    .init(
                        pid: 12345, name: "Synthetic editor", bundleID: "test.synthetic.editor",
                        active: true)
                ]
            }, perform: { _, _ in 0 },
            resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 0) })
    }()
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.model != nil else { throw ExtensionPeerError.unavailable }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "system", command: command, payload: payload,
                    snapshot: { tile in
                        SystemSurface.snapshot(
                            apps: self.operations.list(), tile: tile,
                            cleaning: self.cleaning?.status)
                    },
                    perform: { action in
                        if action == "cleanKeys" || action == "stopCleaning" {
                            guard let cleaning = self.cleaning else {
                                throw ExtensionPeerError.unavailable
                            }
                            _ = try cleaning.execute("system." + action, payload: Data())
                            return
                        }
                        guard
                            let app = self.operations.list().first(where: {
                                "activate:" + $0.pid.description == action
                            }), let running = NSRunningApplication(processIdentifier: app.pid),
                            running.bundleIdentifier == app.bundleID
                        else { throw ExtensionPeerError.invalidRequest }
                        guard running.activate() else {
                            throw ExtensionPeerError.rejected("The app could not open.")
                        }
                    })
            }
            switch command {
            case "system.cli":
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await SystemCLIExecution.run(request, operations: self.operations))
            case "system.apps.snapshot":
                guard payload == Data("{}".utf8), let model = self.model,
                    let presentation = self.presentation
                else { throw ExtensionPeerError.invalidRequest }
                await model.refresh()
                return try JSONEncoder().encode(model.snapshot(presentation: presentation))
            case "system.apps.sort":
                let sort = try JSONDecoder().decode(SystemAppsSort.self, from: payload)
                guard let key = AppSortKey(rawValue: sort.sortKey) else {
                    throw ExtensionPeerError.invalidRequest
                }
                SharedDefaults.store.set(key.rawValue, forKey: RunningAppsKeys.sort)
                SharedDefaults.store.set(sort.ascending, forKey: RunningAppsKeys.ascending)
                self.model?.restoreSort(sort)
                return Data("{}".utf8)
            case "system.cleanKeys", "system.stopCleaning", "system.cleaning.status":
                guard let cleaning = self.cleaning else { throw ExtensionPeerError.unavailable }
                return try cleaning.execute(command, payload: payload)
            case "apps.list":
                return try JSONSerialization.data(
                    withJSONObject: self.operations.list().map(Self.encode))
            case "apps.quit":
                let input = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                let selection: RunningAppSelection
                if input?["all"] as? Bool == true {
                    selection = .all
                } else if let pid = input?["pid"] as? Int, pid > 0, pid <= Int(Int32.max) {
                    selection = .pid(Int32(pid))
                } else if let query = input?["query"] as? String, !query.isEmpty {
                    selection = .query(query)
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
                let plan = try self.operations.plan(
                    selection, force: input?["force"] as? Bool ?? false)
                let outcome = self.operations.apply(
                    plan, confirmed: input?["confirmed"] as? Bool ?? false)
                return try JSONSerialization.data(withJSONObject: [
                    "applied": outcome.applied, "changed": outcome.changed,
                    "targets": plan.targets.map(Self.encode),
                ])
            default: throw ExtensionPeerError.rejected("System does not support this command.")
            }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            cleaning?.shutdown()
            model?.shutdown()
            presentation?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "system", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = RunningAppsModel(operations: operations) }
            if presentation == nil { presentation = SystemPresentationState() }
            if cleaning == nil { cleaning = KeyboardCleaning() }
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient,
                let defaults = UserDefaults(suiteName: configuration.defaultsSuite)
            else { return ["ok": false] as NSDictionary }
            stopUI()
            let presentation = SystemPresentationState(channel: nil)
            uiClient = client
            uiPresentation = presentation
            uiModel = RunningAppsModel(
                engineClient: client, presentation: presentation, defaults: defaults)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel, let presentation = uiPresentation else {
                return ["ok": false] as NSDictionary
            }
            return NSHostingController(
                rootView: ExtensionPageHost { SystemPage(model: model, presentation: presentation) }
            )
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            cleaning?.shutdown()
            cleaning = nil
            model?.shutdown()
            model = nil
            presentation?.shutdown()
            presentation = nil
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        uiModel?.shutdown(); uiModel = nil
        uiPresentation?.shutdown(); uiPresentation = nil
        uiClient?.invalidate(); uiClient = nil
    }

    private static func encode(_ snapshot: RunningAppSnapshot) -> [String: Any] {
        [
            "pid": snapshot.pid, "name": snapshot.name, "bundleID": snapshot.bundleID ?? "",
            "active": snapshot.active, "cpuPercent": snapshot.cpuPercent,
            "memoryMB": snapshot.memoryMB,
        ]
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
