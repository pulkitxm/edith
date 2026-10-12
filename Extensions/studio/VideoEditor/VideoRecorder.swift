import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import EdithExtensionSupport
import EdithExtensionUI

@available(macOS 15.0, *)
@MainActor @Observable
final class VideoRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    var displays: [SCDisplay] = []
    var windows: [SCWindow] = []
    var source = ""
    var systemAudio = true
    var microphone = false
    var showCursor = true
    var recording = false
    var busy = false
    var error: String?
    var startedAt: Date?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var destination: URL?
    private var finished: ((URL) -> Void)?
    private var cursorTask: Task<Void, Never>?
    private var commandsSuspended = false
    private var resetting = false
    private nonisolated let callbacks = StudioTaskOwner()
    private let operations = StudioTaskOwner()
    private var shutdownTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var captureSubmitted = false
    private var nativeFinished = true
    private var nativeWaiters: [CheckedContinuation<Void, Never>] = []
    private var cursorSamples: [[String: Any]] = []
    private var captureRect = CGRect.zero
    private var capturedWindow: CGWindowID?
    private var recordingStart = 0.0
    private var previousButtons = 0

    private final class Reference {
        weak var recorder: VideoRecorder?
        init(_ recorder: VideoRecorder) { self.recorder = recorder }
    }
    private static var active: [Reference] = []
    private static var allCommandsSuspended = false

    override init() {
        super.init()
        if Self.allCommandsSuspended { suspendCommands() }
        Self.active.removeAll { $0.recorder == nil }
        Self.active.append(Reference(self))
    }

    static func shutdownAll() async {
        let recorders = active.compactMap(\.recorder)
        active.removeAll()
        for recorder in recorders { await recorder.shutdown() }
    }

    static func suspendAllCommands() {
        allCommandsSuspended = true
        for recorder in active.compactMap(\.recorder) { recorder.suspendCommands() }
    }

    static func suspendAllCommandsAndWait() async {
        suspendAllCommands()
        let recorders = active.compactMap(\.recorder)
        for recorder in recorders { await recorder.suspendCommandsAndWait() }
    }

    func loadSources() async {
        await performOwned { await self.loadSourcesBody() }
    }

    private func loadSourcesBody() async {
        guard !commandsSuspended, !resetting else { return }
        busy = true
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard !commandsSuspended, !resetting else { throw CancellationError() }
            displays = content.displays
            windows = content.windows.filter {
                $0.isOnScreen && $0.windowLayer == 0
                    && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }
            if source.isEmpty, let display = displays.first {
                source = "display:\(display.displayID)"
            }
            error = nil
        } catch { if !commandsSuspended, !resetting { self.error = error.localizedDescription } }
    }

    func start(finished: @escaping (URL) -> Void) async {
        await performOwned { await self.startBody(finished: finished) }
    }

    private func startBody(finished: @escaping (URL) -> Void) async {
        guard !commandsSuspended, !resetting, !busy, !recording else { return }
        busy = true
        defer { busy = false }
        do {
            if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "Allow microphone access in System Settings to record narration.")
            }
            try Task.checkCancellation()
            guard !commandsSuspended, !resetting else { throw CancellationError() }
            let filter: SCContentFilter
            if let display = displays.first(where: { source == "display:\($0.displayID)" }) {
                filter = SCContentFilter(display: display, excludingWindows: [])
                captureRect = display.frame
                capturedWindow = nil
            } else if let window = windows.first(where: { source == "window:\($0.windowID)" }) {
                filter = SCContentFilter(desktopIndependentWindow: window)
                captureRect = window.frame
                capturedWindow = window.windowID
            } else {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "Choose a display or window first.")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = max(
                2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)) / 2 * 2)
            configuration.height = max(
                2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)) / 2 * 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.capturesAudio = systemAudio
            configuration.captureMicrophone = microphone
            configuration.excludesCurrentProcessAudio = true
            configuration.showsCursor = showCursor
            let directory = VideoProject.libraryURL.appendingPathComponent(
                "Recordings", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Recording-\(UUID().uuidString).mp4")
            let settings = SCRecordingOutputConfiguration()
            settings.outputURL = url
            settings.outputFileType = .mp4
            settings.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: settings, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addRecordingOutput(output)
            self.output = output
            self.stream = stream
            captureStopTask = nil
            captureSubmitted = false
            nativeFinished = false
            destination = url
            self.finished = finished
            cursorSamples.removeAll()
            captureSubmitted = true
            try await stream.startCapture()
            try Task.checkCancellation()
            guard !commandsSuspended, !resetting else { throw CancellationError() }
            recording = true
            error = nil
        } catch {
            if commandsSuspended || resetting { return }
            await stopNativeCapture()
            reset()
            self.error = error.localizedDescription
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        callbacks.enqueue { [self] in
            guard !commandsSuspended, !resetting, recordingOutput === output else { return }
            startedAt = Date()
            recordingStart = ProcessInfo.processInfo.systemUptime
            previousButtons = NSEvent.pressedMouseButtons
            cursorTask?.cancel()
            cursorTask = callbacks.start { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await sampleCursor()
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
    }

    private func sampleCursor() async {
        if let capturedWindow {
            let rect = await Task.detached(priority: .userInitiated) {
                guard
                    let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, capturedWindow)
                        as? [[String: Any]],
                    let raw = windows.first?[kCGWindowBounds as String] as? [String: Any]
                else { return CGRect?.none }
                return CGRect(dictionaryRepresentation: raw as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let rect { captureRect = rect }
        }
        guard captureRect.width > 0, captureRect.height > 0,
            let point = CGEvent(source: nil)?.location
        else { return }
        let buttons = NSEvent.pressedMouseButtons
        cursorSamples.append([
            "timeMs": (ProcessInfo.processInfo.systemUptime - recordingStart) * 1000,
            "cx": (point.x - captureRect.minX) / captureRect.width,
            "cy": (point.y - captureRect.minY) / captureRect.height,
            "visible": captureRect.contains(point),
            "interactionType": buttons != 0 && buttons != previousButtons ? "click" : "move",
        ])
        previousButtons = buttons
    }

    func stop() async {
        await performOwned { await self.stopBody() }
    }

    private func stopBody() async {
        guard !commandsSuspended, !resetting, let stream, recording, !busy else { return }
        busy = true
        do { try await stream.stopCapture() } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        callbacks.enqueue { [self] in
            guard recordingOutput === self.output else { return }
            finishNativeCapture()
            guard !commandsSuspended, !resetting else { return }
            let url = destination
            let completion = finished
            if let url {
                do {
                    try JSONSerialization.data(withJSONObject: ["samples": cursorSamples])
                        .write(
                            to: URL(fileURLWithPath: url.path + ".cursor.json"), options: .atomic)
                } catch {
                    self.error =
                        "Video saved, but cursor data could not be saved: \(error.localizedDescription)"
                }
            }
            reset()
            if let url { completion?(url) }
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput, didFailWithError error: any Error
    ) {
        callbacks.enqueue { [self] in
            guard recordingOutput === self.output else { return }
            finishNativeCapture()
            guard !commandsSuspended, !resetting else { return }
            let active = stream
            reset()
            self.error = error.localizedDescription
            try? await active?.stopCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        callbacks.enqueue { [self] in
            guard !self.commandsSuspended, !self.resetting, stream === self.stream else { return }
            self.error = error.localizedDescription
            cursorTask?.cancel()
            cursorTask = nil
            recording = false
            busy = false
        }
    }

    func suspendCommands() {
        commandsSuspended = true
        operations.shutdown()
        cursorTask?.cancel()
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        let ownedShutdown = shutdownTask
        await operations.shutdownAndWait()
        await stopNativeCapture()
        await ownedShutdown?.value
        await callbacks.shutdownAndWait()
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        resetting = true
        cursorTask?.cancel()
        let task = Task {
            await operations.cancelPendingWorkAndWait()
            await stopNativeCapture()
            await callbacks.waitForPendingWork()
            reset()
            resetting = false
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func stopNativeCapture() async {
        if let captureStopTask { await captureStopTask.value; return }
        let task = Task {
            if let active = stream, captureSubmitted {
                do { try await active.stopCapture() } catch { self.error = error.localizedDescription }
                if !nativeFinished {
                    await withCheckedContinuation { nativeWaiters.append($0) }
                }
            }
        }
        captureStopTask = task
        await task.value
    }

    private func finishNativeCapture() {
        nativeFinished = true
        let waiting = nativeWaiters
        nativeWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func performOwned(_ operation: @escaping @MainActor () async -> Void) async {
        guard !commandsSuspended, !resetting, let task = operations.start(operation) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func reset() {
        cursorTask?.cancel()
        cursorTask = nil
        cursorSamples.removeAll()
        captureSubmitted = false
        nativeFinished = true
        captureStopTask = nil
        stream = nil
        output = nil
        destination = nil
        finished = nil
        recording = false
        busy = false
        startedAt = nil
    }
}

@available(macOS 15.0, *)
struct VideoRecorderSheet: View {
    let finished: (URL) -> Void
    @State private var recorder = StudioUIRecorder()
    @Environment(\.studioFacade) private var facade
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Record a video", systemImage: "record.circle").font(.edithText(.title2).bold())
            if recorder.recording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "Recording · \(Int(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))s"
                    )
                    .font(.edithText(.title3).monospacedDigit()).foregroundStyle(.red)
                }
                Text("Stop recording to open the finished video in the editor.").foregroundStyle(
                    .secondary)
                Button(recorder.busy ? "Finishing…" : "Stop recording") {
                    Task { await recorder.stop() }
                }
                .buttonStyle(.edith(.primary)).disabled(recorder.busy)
            } else {
                Picker("Source", selection: $recorder.source) {
                    Text("Choose a source").tag("")
                    ForEach(recorder.sources, id: \.id) { source in
                        Text(source.title).tag(source.id)
                    }
                }
                Toggle("System audio", isOn: $recorder.systemAudio)
                Toggle("Microphone", isOn: $recorder.microphone)
                Toggle("Include cursor", isOn: $recorder.showCursor)
                HStack {
                    Button("Refresh sources") { Task { await recorder.loadSources() } }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Start recording") {
                        Task {
                            await recorder.start { url in
                                finished(url)
                                dismiss()
                            }
                        }
                    }.buttonStyle(.edith(.primary)).disabled(recorder.source.isEmpty)
                }
                .disabled(recorder.busy)
            }
            if let error = recorder.error {
                Text(error).font(.edithText(.callout)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24).frame(width: UIScale.pt(480))
        .transientPresentation(dismissible: !recorder.recording && !recorder.busy)
        .pageTask {
            recorder.configure(facade); await recorder.loadSources()
        }
        .onDisappear { Task { await recorder.shutdown() } }
    }
}
