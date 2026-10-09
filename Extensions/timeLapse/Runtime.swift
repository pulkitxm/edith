import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithTimeLapseExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var recorder: NSObject?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard #available(macOS 15.0, *), let recorder = self?.recorder as? TimeLapseRecorder
            else {
                throw ExtensionPeerError.unavailable
            }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "timeLapse", command: command, payload: payload,
                    snapshot: { tile in
                        let library = TimeLapseRecorder.libraryURL
                        let recordings = try await BlockingWork.perform {
                            try TimeLapseRecording.load(in: library)
                        }
                        return TimeLapseSurface.snapshot(
                            recorder, recordings: recordings, tile: tile)
                    },
                    perform: { action in
                        if action == "stop" {
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

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        Task {
            if #available(macOS 15.0, *), let recorder = recorder as? TimeLapseRecorder {
                await recorder.shutdown()
            }
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
            guard #available(macOS 15.0, *), let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else {
                return ["ok": false] as NSDictionary
            }
            if recorder == nil { recorder = TimeLapseRecorder() }
        case "view":
            guard #available(macOS 15.0, *), let recorder = recorder as? TimeLapseRecorder else {
                return ["ok": false] as NSDictionary
            }
            return NSHostingController(
                rootView: ExtensionPageHost { TimeLapseControls(recorder: recorder) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            recorder = nil
        case "status": return ["ok": true, "running": recorder != nil] as NSDictionary
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
