import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import EdithKit

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
    private var cursorSamples: [[String: Any]] = []
    private var captureRect = CGRect.zero
    private var capturedWindow: CGWindowID?
    private var recordingStart = 0.0
    private var previousButtons = 0

    func loadSources() async {
        busy = true
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            displays = content.displays
            windows = content.windows.filter {
                $0.frame.width > 100 && $0.frame.height > 100 && !($0.title ?? "").isEmpty
            }
            if source.isEmpty, let display = displays.first {
                source = "display:\(display.displayID)"
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func start(finished: @escaping (URL) -> Void) async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        do {
            if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw VideoRenderPipeline.RenderError.exportFailed(
                    "Allow microphone access in System Settings to record narration.")
            }
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
            destination = url
            self.finished = finished
            cursorSamples.removeAll()
            try await stream.startCapture()
            recording = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            stream = nil
            output = nil
            destination = nil
            self.finished = nil
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [self] in
            guard recordingOutput === output else { return }
            startedAt = Date()
            recordingStart = ProcessInfo.processInfo.systemUptime
            previousButtons = NSEvent.pressedMouseButtons
            cursorTask = Task { [weak self] in
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
        guard let stream, recording, !busy else { return }
        busy = true
        do { try await stream.stopCapture() } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard recordingOutput === output else { return }
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
        Task { @MainActor in
            guard recordingOutput === output else { return }
            let active = stream
            reset()
            self.error = error.localizedDescription
            try? await active?.stopCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard stream === self.stream else { return }
            self.error = error.localizedDescription
            cursorTask?.cancel()
            cursorTask = nil
            recording = false
            busy = false
        }
    }

    private func reset() {
        cursorTask?.cancel()
        cursorTask = nil
        cursorSamples.removeAll()
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
    @State private var recorder = VideoRecorder()
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
                    ForEach(Array(recorder.displays.enumerated()), id: \.element.displayID) {
                        index, display in
                        Text("Display \(index + 1)").tag("display:\(display.displayID)")
                    }
                    ForEach(recorder.windows, id: \.windowID) { window in
                        Text(
                            "\(window.owningApplication?.applicationName ?? "App"): \(window.title ?? "Window")"
                        )
                        .tag("window:\(window.windowID)")
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
        .task { await recorder.loadSources() }
    }
}
