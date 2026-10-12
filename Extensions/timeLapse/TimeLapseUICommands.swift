import AppKit
import EdithExtensionSupport
import Foundation

struct TimeLapseUISnapshot: Codable {
    let settings: TimeLapseSettings
    let displays: [TimeLapseDisplayChoice]
    let windows: [TimeLapseWindowChoice]
    let microphones: [TimeLapseMicrophoneChoice]
    let sourceMode: String
    let selectedDisplays: Set<UInt32>
    let selectedWindows: Set<UInt32>
    let microphone: String
    let recording: Bool
    let busy: Bool
    let error: String?
    let startedAt: Date?
    let frames: Int64
    let bytes: Int64
    let playbackSeconds: Double
    let lastDirectory: URL?
    let preview: Data?
    let sourceRevision: Int
    let sourceError: String?
    let sourcesLoaded: Bool
}
struct TimeLapseUIStart: Codable {
    let settings: TimeLapseSettings; let sourceMode: String; let displays: Set<UInt32>;
    let windows: Set<UInt32>; let microphone: String
}
struct TimeLapseUIExport: Codable {
    let id: UUID; let quality: TimeLapseExportQuality; let destination: String
}
struct TimeLapseUIExportStatus: Codable { let token: UUID; let complete: Bool; let error: String? }
struct TimeLapseUIThumbnail: Codable { let mode: String; let id: UInt32 }
struct TimeLapseUIImage: Codable { let image: Data? }

@available(macOS 15.0, *) @MainActor final class TimeLapseUICommands: NSObject {
    private let recorder: TimeLapseRecorder
    private let previewConsumer = UUID()
    private var previewLease: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var actionEpoch = UUID()
    private var exportTask: Task<Void, Never>?
    private var exportLease: Task<Void, Never>?
    private var exportStatus: TimeLapseUIExportStatus?
    init(recorder: TimeLapseRecorder) { self.recorder = recorder }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try recorder.requireExportLibraryCurrent()
        if recorder.exportOnly {
            guard
                [
                    "recording.ui.snapshot", "recording.ui.sources", "recording.ui.library",
                    "recording.ui.export", "recording.ui.exportPoll", "recording.ui.exportCancel",
                ].contains(command)
            else { throw ExtensionPeerError.invalidRequest }
        }
        switch command {
        case "recording.ui.snapshot":
            let values = try JSONDecoder().decode([String: Bool].self, from: payload)
            guard Set(values.keys) == ["preview"] else { throw ExtensionPeerError.invalidRequest }
            if values["preview"] == true { renewPreviewLease() }
        case "recording.ui.sources":
            try empty(payload)
            await recorder.loadSources()
        case "recording.ui.thumbnail":
            let input = try JSONDecoder().decode(TimeLapseUIThumbnail.self, from: payload)
            guard input.mode == "displays" || input.mode == "windows" else {
                throw ExtensionPeerError.invalidRequest
            }
            let image = await recorder.sourceThumbnail(mode: input.mode, id: input.id)
            return try JSONEncoder().encode(
                TimeLapseUIImage(
                    image: image.flatMap {
                        NSBitmapImageRep(cgImage: $0).representation(
                            using: .jpeg, properties: [.compressionFactor: 0.75])
                    }))
        case "recording.ui.start":
            let input = try JSONDecoder().decode(TimeLapseUIStart.self, from: payload)
            try input.settings.validate()
            guard action == nil, !recorder.recording, !recorder.busy,
                ["displays", "windows"].contains(input.sourceMode), input.displays.count <= 16,
                input.windows.count <= 16,
                input.displays.isSubset(of: Set(recorder.displays.map(\.id))),
                input.windows.isSubset(of: Set(recorder.windows.map(\.id))),
                input.microphone.isEmpty || input.microphone == "default"
                    || recorder.microphones.contains(where: { $0.id == input.microphone })
            else { throw ExtensionPeerError.invalidRequest }
            recorder.settings = input.settings; recorder.sourceMode = input.sourceMode
            recorder.selectedDisplays = input.displays; recorder.selectedWindows = input.windows
            recorder.microphone = input.microphone
            guard recorder.canStart else { throw ExtensionPeerError.invalidRequest }
            let epoch = UUID(); actionEpoch = epoch
            action = launch { [self] in
                await recorder.start()
                if actionEpoch == epoch { action = nil }
            }
            await Task.yield()
        case "recording.ui.stop":
            try empty(payload)
            action?.cancel()
            let epoch = UUID(); actionEpoch = epoch
            action = launch { [self] in
                await recorder.stop()
                if actionEpoch == epoch { action = nil }
            }
            await Task.yield()
        case "recording.ui.permission":
            try empty(payload)
            _ = CGRequestScreenCaptureAccess()
        case "recording.ui.library":
            try empty(payload)
            return try JSONEncoder().encode(try await recorder.readRecordings())
        case "recording.ui.export":
            let input = try JSONDecoder().decode(TimeLapseUIExport.self, from: payload)
            guard input.destination.hasPrefix("/"), !input.destination.utf8.contains(0) else {
                throw ExtensionPeerError.invalidRequest
            }
            let recordings = try await recorder.readRecordings()
            guard let recording = recordings.first(where: { $0.id == input.id }),
                recording.directory != recorder.lastDirectory || !recorder.recording
            else { throw ExtensionPeerError.invalidRequest }
            guard exportTask == nil else {
                throw ExtensionPeerError.rejected("An export is already running.")
            }
            let token = UUID()
            exportStatus = .init(token: token, complete: false, error: nil)
            exportTask = launch { [self] in
                do {
                    try await recorder.exportRecording(
                        recording, quality: input.quality,
                        to: URL(fileURLWithPath: input.destination))
                    if !stopped { exportStatus = .init(token: token, complete: true, error: nil) }
                } catch {
                    if !stopped {
                        exportStatus = .init(
                            token: token, complete: true, error: error.localizedDescription)
                    }
                }
                exportTask = nil
            }
            renewExportLease(token)
            return try JSONEncoder().encode(exportStatus)
        case "recording.ui.exportPoll", "recording.ui.exportCancel":
            let values = try JSONDecoder().decode([String: UUID].self, from: payload)
            guard Set(values.keys) == ["token"], let status = exportStatus,
                values["token"] == status.token
            else { throw ExtensionPeerError.invalidRequest }
            if command == "recording.ui.exportCancel" {
                let pending = exportTask
                pending?.cancel()
                await pending?.value
            } else if !status.complete {
                renewExportLease(status.token)
            }
            try recorder.requireExportLibraryCurrent()
            return try JSONEncoder().encode(exportStatus)
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return try JSONEncoder().encode(recorder.uiSnapshot())
    }
    private func empty(_ data: Data) throws {
        guard data == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
    }
    private func renewPreviewLease() {
        recorder.showPreview(true, consumer: previewConsumer)
        previewLease?.cancel()
        previewLease = launch { [self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            recorder.showPreview(false, consumer: previewConsumer)
        }
    }
    private func renewExportLease(_ token: UUID) {
        exportLease?.cancel()
        exportLease = launch { [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if exportStatus?.token == token && exportStatus?.complete == false {
                exportTask?.cancel()
            }
        }
    }
    func shutdownAndWait() async {
        let pending = Array(tasks.values)
        shutdown()
        for task in pending { await task.value }
    }
    private func launch(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [self] in
            defer { tasks[id] = nil }
            guard !stopped, !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }

    func shutdown() {
        for task in tasks.values { task.cancel() }
        exportTask?.cancel(); exportLease?.cancel()
        stopped = true; action?.cancel(); action = nil
        previewLease?.cancel(); previewLease = nil
        recorder.showPreview(false, consumer: previewConsumer)
    }
}
