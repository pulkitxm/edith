#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithTimeLapseExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var recorder: NSObject?
    private var uiRecorder: NSObject?
    private var uiClient: ExtensionEngineClient?
    private var uiOperations: NSObject?
    private var uiLocation: String?
    private var draining = false
    private var uiStops: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard #available(macOS 15.0, *), let recorder = self?.recorder as? TimeLapseRecorder
            else {
                throw ExtensionPeerError.unavailable
            }
            if command.hasPrefix("recording.ui."),
                let operations = self?.uiOperations as? TimeLapseUICommands
            {
                if recorder.exportOnly {
                    guard let value = request["token"] as? String,
                        let token = UUID(uuidString: value)
                    else { throw ExtensionPeerError.invalidRequest }
                    return try await recorder.performExportRequest(
                        token: token, command: command, payload: payload
                    ) {
                        try await operations.execute(command, payload: payload)
                    }
                }
                return try await operations.execute(command, payload: payload)
            }
            guard !recorder.exportOnly else { throw ExtensionPeerError.invalidRequest }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "timeLapse", command: command, payload: payload,
                    snapshot: { tile in
                        let library = TimeLapseRecorder.libraryURL
                        let loaded = try await BlockingWork.perform {
                            try TimeLapseRecording.load(in: library, limit: 512)
                        }
                        return TimeLapseSurface.snapshot(
                            recorder, recordings: loaded.recordings, truncated: loaded.truncated,
                            tile: tile)
                    },
                    perform: { action in
                        if action == "open" {
                            ExtensionPresentation.showWindow()
                        } else if action.hasPrefix("stop:") {
                            guard recorder.recording, !recorder.busy,
                                let id = recorder.activeSession,
                                action == "stop:" + id.uuidString
                            else { throw ExtensionPeerError.invalidRequest }
                            await recorder.stop()
                        } else {
                            let library = TimeLapseRecorder.libraryURL
                            let recordings = try await BlockingWork.perform {
                                try TimeLapseRecording.load(in: library)
                            }
                            guard
                                let recording = recordings.first(where: {
                                    "reveal:" + $0.id.uuidString == action
                                })
                            else { throw ExtensionPeerError.invalidRequest }
                            NSWorkspace.shared.activateFileViewerSelecting([recording.directory])
                        }
                    })
            }
            switch command {
            case "recording.status":
                return try JSONSerialization.data(withJSONObject: [
                    "recording": recorder.recording, "busy": recorder.busy,
                    "frames": recorder.frames, "bytes": recorder.bytes,
                    "playbackSeconds": recorder.playbackSeconds,
                ])
            case "recording.stop":
                await recorder.stop()
                return try JSONSerialization.data(withJSONObject: ["recording": recorder.recording])
            case "recording.list":
                let recordings = try TimeLapseRecording.load(in: TimeLapseRecorder.libraryURL)
                return try JSONEncoder().encode(recordings.map(\.session))
            default:
                throw ExtensionPeerError.rejected("Screen Recorder does not support this command.")
            }
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        draining = true
        let recorder = recorder, operations = uiOperations
        if #available(macOS 15.0, *) { (recorder as? TimeLapseRecorder)?.beginSuspension() }
        _ = commands.suspend()
        stopUI()
        if #available(macOS 15.0, *) { (operations as? TimeLapseUICommands)?.shutdown() }
        Task { [self, recorder, operations] in
            _ = await commands.suspendAndWait()
            if #available(macOS 15.0, *) {
                await (operations as? TimeLapseUICommands)?.shutdownAndWait()
                await (recorder as? TimeLapseRecorder)?.suspendAndWait()
            }
            for task in Array(uiStops.values) { await task.value }
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        draining = true
        let recorder = recorder, operations = uiOperations
        Task { [self, recorder, operations] in
            if #available(macOS 15.0, *) {
                if let recorder = recorder as? TimeLapseRecorder, recorder.recording {
                    await recorder.stop()
                }
                await (operations as? TimeLapseUICommands)?.finishExport()
                (recorder as? TimeLapseRecorder)?.beginSuspension()
            }
            commands.shutdown()
            stopUI()
            if #available(macOS 15.0, *) { (operations as? TimeLapseUICommands)?.shutdown() }
            await commands.shutdownAndWait()
            if #available(macOS 15.0, *) {
                await (operations as? TimeLapseUICommands)?.shutdownAndWait()
            }
            if #available(macOS 15.0, *), let recorder = recorder as? TimeLapseRecorder {
                await recorder.shutdown()
            }
            for task in Array(uiStops.values) { await task.value }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "timeLapse", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !draining, #available(macOS 15.0, *),
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else {
                return ["ok": false] as NSDictionary
            }
            if recorder == nil {
                do {
                    let created: TimeLapseRecorder
                    #if canImport(WorkerFixtureSupport)
                    if let library = try TimeLapseExportLibrary.signed(
                        context: input, roleBundle: Bundle(for: ExtensionRuntime.self))
                    {
                        created = TimeLapseRecorder(exportLibrary: library)
                    } else {
                        guard !TimeLapseExportIntent.present(input) else {
                            return ["ok": false] as NSDictionary
                        }
                        created = TimeLapseRecorder()
                    }
                    #else
                    guard !TimeLapseExportIntent.functional(input) else {
                        return ["ok": false] as NSDictionary
                    }
                    created = TimeLapseRecorder()
                    #endif
                    recorder = created
                    uiOperations = TimeLapseUICommands(recorder: created)
                } catch { return ["ok": false] as NSDictionary }
            }
        case "configureUI":
            if input["location"] as? String == "settings" {
                guard !draining, input["section"] as? String == "extension" else {
                    return ["ok": false] as NSDictionary
                }
                stopUI(); uiLocation = "settings"
                return ["ok": true] as NSDictionary
            }
            guard !draining, uiStops.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiLocation = nil
            if #available(macOS 15.0, *) { uiRecorder = TimeLapseRecorder(engineClient: client) }
        case "stopUI": stopUI()
        case "view":
            if uiLocation == "settings" {
                return NSHostingController(rootView: ExtensionPageHost { TimeLapseSettingsPage() })
            }
            guard uiClient != nil else { return ["ok": false] as NSDictionary }
            guard #available(macOS 15.0, *), let recorder = uiRecorder as? TimeLapseRecorder else {
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        ContentUnavailableView(
                            "Screen Recorder needs macOS 15", systemImage: "record.circle",
                            description: Text(
                                "Update macOS to record displays, windows and optional audio."))
                    })
            }
            return NSHostingController(
                rootView: ExtensionPageHost { TimeLapseControls(recorder: recorder) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            prepareToStop { [self] in
                uiOperations = nil; recorder = nil
            }
        case "status": return ["ok": true, "running": recorder != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        let client = uiClient; uiClient = nil
        let recorder = uiRecorder; uiRecorder = nil
        if #available(macOS 15.0, *) { (recorder as? TimeLapseRecorder)?.beginSuspension() }
        if let recorder {
            let id = UUID()
            uiStops[id] = Task { [self, recorder, client] in
                defer { client?.invalidate(); uiStops[id] = nil }
                if #available(macOS 15.0, *) { await (recorder as? TimeLapseRecorder)?.shutdown() }
            }
        }
        if recorder == nil { client?.invalidate() }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}

private enum TimeLapseExportIntent {
    static func functional(_ context: NSDictionary) -> Bool {
        ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || context["hostedFunctionalFixture"] != nil
    }

    static func present(_ context: NSDictionary) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return functional(context)
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || (context["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.") == true
            || Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
    }
}
