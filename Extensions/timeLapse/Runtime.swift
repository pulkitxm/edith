#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class TimeLapseService: ExtensionService {
    private var recorder: NSObject?
    private var uiRecorder: NSObject?
    private var uiClient: ExtensionEngineClient?
    private var uiOperations: NSObject?
    private var uiLocation: String?
    private var uiStops: [UUID: Task<Void, Never>] = [:]

    var isRunning: Bool { recorder != nil }
    var allowsUIDuringRetirement: Bool { true }

    func invoke(_ command: String, token: UUID, payload: Data) async throws -> Data {
        guard #available(macOS 15.0, *), let recorder = self.recorder as? TimeLapseRecorder
        else {
            throw ExtensionPeerError.unavailable
        }
        if command.hasPrefix("recording.ui."),
            let operations = self.uiOperations as? TimeLapseUICommands
        {
            if recorder.exportOnly {
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

    func start(_ context: ExtensionHostContext) -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        let input = context.input
        if recorder == nil {
            do {
                let created: TimeLapseRecorder
                #if canImport(WorkerFixtureSupport)
                if let library = try TimeLapseExportLibrary.signed(
                    context: input, roleBundle: Bundle(for: TimeLapseService.self))
                {
                    created = TimeLapseRecorder(exportLibrary: library)
                } else {
                    guard !TimeLapseExportIntent.present(input) else { return false }
                    created = TimeLapseRecorder()
                }
                #else
                guard !TimeLapseExportIntent.functional(input) else { return false }
                created = TimeLapseRecorder()
                #endif
                recorder = created
                uiOperations = TimeLapseUICommands(recorder: created)
            } catch { return false }
        }
        return true
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        if configuration.isSettings {
            guard configuration.section == "extension" else { return false }
            _ = releaseUI()
            configuration.engineClient?.invalidate()
            uiLocation = "settings"
            return true
        }
        guard uiStops.isEmpty, let client = configuration.engineClient else { return false }
        _ = releaseUI()
        uiClient = client
        uiLocation = nil
        if #available(macOS 15.0, *) { uiRecorder = TimeLapseRecorder(engineClient: client) }
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        if uiLocation == "settings" {
            return NSHostingController(rootView: ExtensionPageHost { TimeLapseSettingsPage() })
        }
        guard uiClient != nil else { return nil }
        guard #available(macOS 15.0, *), let recorder = uiRecorder as? TimeLapseRecorder else {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ContentUnavailableView {
                        Label("Screen Recorder needs macOS 15", edith: .record)
                    } description: {
                        Text("Update macOS to record displays, windows and optional audio.")
                    }
                })
        }
        return NSHostingController(
            rootView: ExtensionPageHost { TimeLapseControls(recorder: recorder) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        releaseUI().map { [$0] } ?? []
    }

    func finishBeforeStop() async {
        if #available(macOS 15.0, *) {
            if let recorder = recorder as? TimeLapseRecorder, recorder.recording {
                await recorder.stop()
            }
            await (uiOperations as? TimeLapseUICommands)?.finishExport()
        }
    }

    func cancelPendingWork() {
        if #available(macOS 15.0, *) {
            (recorder as? TimeLapseRecorder)?.beginSuspension()
        }
        _ = releaseUI()
        if #available(macOS 15.0, *) { (uiOperations as? TimeLapseUICommands)?.shutdown() }
    }

    func drain() async {
        if #available(macOS 15.0, *) {
            await (uiOperations as? TimeLapseUICommands)?.shutdownAndWait()
            await (recorder as? TimeLapseRecorder)?.suspendAndWait()
        }
        for task in Array(uiStops.values) { await task.value }
    }

    func teardown() async {
        _ = releaseUI()
        let owned = recorder
        recorder = nil
        uiOperations = nil
        if #available(macOS 15.0, *), let owned = owned as? TimeLapseRecorder {
            await owned.shutdown()
        }
        for task in Array(uiStops.values) { await task.value }
    }

    private func releaseUI() -> Task<Void, Never>? {
        let client = uiClient
        uiClient = nil
        let recorder = uiRecorder
        uiRecorder = nil
        if #available(macOS 15.0, *) { (recorder as? TimeLapseRecorder)?.beginSuspension() }
        guard let recorder else {
            client?.invalidate()
            return nil
        }
        let id = UUID()
        let task = Task { [self, recorder, client] in
            defer {
                client?.invalidate()
                uiStops[id] = nil
            }
            if #available(macOS 15.0, *) { await (recorder as? TimeLapseRecorder)?.shutdown() }
        }
        uiStops[id] = task
        return task
    }
}

@MainActor
func makeTimeLapseRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "timeLapse", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in TimeLapseService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeTimeLapseRuntime()).toOpaque())
        })
}

private enum TimeLapseExportIntent {
    static func functional(_ context: NSDictionary) -> Bool {
        ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || context["hostedFunctionalFixture"] != nil
    }

    static func present(_ context: NSDictionary) -> Bool {
        let environment = ExtensionEnvironment.values
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
