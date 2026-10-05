import AVFoundation
import AppKit
import EdithCore
import EdithKit
import IOKit.pwr_mgt
import Observation
import ScreenCaptureKit

@available(macOS 15.0, *)
@MainActor @Observable
final class TimeLapseRecorder: NSObject, SCStreamDelegate {
    static let shared = TimeLapseRecorder()
    var settings = TimeLapseSettings()
    var displays: [TimeLapseDisplayChoice] = []
    var windows: [TimeLapseWindowChoice] = []
    var microphones: [TimeLapseMicrophoneChoice] = []
    var sourceMode = "displays"
    var selectedDisplays: Set<CGDirectDisplayID> = []
    var selectedWindows: Set<CGWindowID> = []
    var microphone = ""
    var recording = false
    var busy = false
    var error: String?
    var startedAt: Date?
    var frames: Int64 = 0
    var bytes: Int64 = 0
    var lastDirectory: URL?
    var preview: CGImage?
    private var previewVisible = false
    private var streams: [SCStream] = []
    private var outputs: [TimeLapseCaptureOutput] = []
    private var writer: TimeLapseWriter?
    private var sleepAssertions: [IOPMAssertionID] = []

    var canStart: Bool {
        !busy && !recording
            && (sourceMode == "displays" ? !selectedDisplays.isEmpty : !selectedWindows.isEmpty)
    }

    static var libraryURL: URL {
        VideoProject.libraryURL.appendingPathComponent("TimeLapses", isDirectory: true)
    }

    func loadSources() async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        do {
            let sources = try await TimeLapseSources.load()
            displays = sources.displayChoices
            windows = sources.windowChoices
            selectedDisplays.formIntersection(sources.displayIDs)
            selectedWindows.formIntersection(sources.windowIDs)
            if selectedDisplays.isEmpty, let first = displays.first {
                selectedDisplays.insert(first.id)
            }
            microphones = await TimeLapseMicrophoneChoice.load()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func showPreview(_ visible: Bool) {
        previewVisible = visible
        writer?.setPreviewEnabled(visible)
    }

    func start() async {
        guard canStart else { return }
        busy = true
        error = nil
        preview = nil
        defer { busy = false }
        do {
            settings.microphoneID = microphone.isEmpty ? nil : microphone
            try settings.validate()
            if settings.microphoneID != nil {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw TimeLapseError.encoding(
                        "Allow microphone access in System Settings to record audio.")
                }
                if microphone != "default",
                    !microphones.contains(where: { $0.id == microphone })
                {
                    throw TimeLapseError.encoding(
                        "The selected microphone is unavailable. Refresh sources.")
                }
            }
            let sources = try await TimeLapseSources.load()
            let plan = try await sources.plan(
                mode: sourceMode, displays: selectedDisplays,
                windows: selectedWindows, settings: settings)
            let filters = plan.filters
            let columns = plan.columns
            let rows = plan.rows
            let size = (width: plan.width, height: plan.height)
            let session = TimeLapseSession(
                settings: settings, width: size.width, height: size.height)
            let directory = Self.libraryURL.appendingPathComponent(
                session.id.uuidString, isDirectory: true)
            let writer = try TimeLapseWriter(
                directory: directory, session: session, sourceCount: filters.count,
                failure: { [weak self] message in
                    Task { @MainActor in
                        guard let self else { return }
                        self.error = message
                        await self.stop(reason: message)
                    }
                },
                progress: { [weak self] frames, bytes in
                    Task { @MainActor in
                        self?.frames = frames; self?.bytes = bytes
                    }
                },
                preview: { [weak self] image in
                    Task { @MainActor in
                        guard let self, self.recording else { return }
                        self.preview = image
                    }
                })
            writer.setPreviewEnabled(previewVisible)
            self.writer = writer
            lastDirectory = directory
            for (index, filter) in filters.enumerated() {
                let configuration = SCStreamConfiguration()
                let sourceSize = settings.dimensions(
                    width: Double(filter.contentRect.width) * Double(filter.pointPixelScale),
                    height: Double(filter.contentRect.height) * Double(filter.pointPixelScale))
                let scale = min(
                    Double(size.width) / Double(columns) / Double(sourceSize.width),
                    Double(size.height) / Double(rows) / Double(sourceSize.height), 1)
                configuration.width = max(2, Int(Double(sourceSize.width) * scale) / 2 * 2)
                configuration.height = max(2, Int(Double(sourceSize.height) * scale) / 2 * 2)
                configuration.minimumFrameInterval = CMTime(
                    seconds: settings.interval, preferredTimescale: 600)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = settings.showCursor
                configuration.capturesAudio = false
                configuration.captureMicrophone = false
                configuration.microphoneCaptureDeviceID =
                    microphone == "default" ? nil : settings.microphoneID
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48000
                configuration.channelCount = 2
                let output = TimeLapseCaptureOutput(writer: writer, index: index)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writer.queue)
                streams.append(stream)
                outputs.append(output)
                try await stream.startCapture()
                if let error { throw TimeLapseError.encoding(error) }
            }
            if settings.systemAudio || settings.microphoneID != nil {
                let configuration = SCStreamConfiguration()
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(seconds: 60, preferredTimescale: 600)
                configuration.queueDepth = 3
                configuration.capturesAudio = settings.systemAudio
                configuration.captureMicrophone = settings.microphoneID != nil
                configuration.microphoneCaptureDeviceID =
                    microphone == "default" ? nil : settings.microphoneID
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48000
                configuration.channelCount = 2
                let output = TimeLapseCaptureOutput(writer: writer, index: -1)
                let stream = SCStream(
                    filter: plan.audioFilter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writer.queue)
                if settings.systemAudio {
                    try stream.addStreamOutput(
                        output, type: .audio, sampleHandlerQueue: writer.queue)
                }
                if settings.microphoneID != nil {
                    try stream.addStreamOutput(
                        output, type: .microphone, sampleHandlerQueue: writer.queue)
                }
                streams.append(stream)
                outputs.append(output)
                try await stream.startCapture()
                if let error { throw TimeLapseError.encoding(error) }
            }
            if settings.keepAwake {
                for type in [
                    kIOPMAssertionTypePreventUserIdleDisplaySleep,
                    kIOPMAssertionTypePreventUserIdleSystemSleep,
                ] {
                    var assertion: IOPMAssertionID = 0
                    let result = IOPMAssertionCreateWithName(
                        type as CFString,
                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                        "Screen time-lapse recording" as CFString,
                        &assertion)
                    guard result == kIOReturnSuccess else {
                        throw TimeLapseError.encoding(
                            "Could not keep this Mac awake. Disable Keep Mac and screen awake to continue."
                        )
                    }
                    sleepAssertions.append(assertion)
                }
            }
            frames = 0
            bytes = 0
            startedAt = Date()
            recording = true
            error = nil
            writer.startTimer()
        } catch {
            self.error = error.localizedDescription
            for stream in streams { try? await stream.stopCapture() }
            streams.removeAll()
            outputs.removeAll()
            if let writer { _ = await writer.stop(reason: error.localizedDescription) }
            self.writer = nil
            releaseSleepAssertion()
        }
    }

    func stop(reason: String? = nil) async {
        guard !busy, let writer else { return }
        busy = true
        for stream in streams {
            do { try await stream.stopCapture() } catch {
                self.error = error.localizedDescription
            }
        }
        streams.removeAll()
        outputs.removeAll()
        let session = await writer.stop(reason: reason ?? error)
        error = session.failure
        self.writer = nil
        releaseSleepAssertion()
        recording = false
        busy = false
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard streams.contains(where: { $0 === stream }) else { return }
            self.error = error.localizedDescription
            await stop(reason: error.localizedDescription)
        }
    }

    func defersQuit(_ sender: NSApplication) -> Bool {
        guard recording || busy else { return false }
        Task {
            while busy { try? await Task.sleep(for: .milliseconds(100)) }
            await stop()
            sender.terminate(nil)
        }
        return true
    }

    private func releaseSleepAssertion() {
        for assertion in sleepAssertions { IOPMAssertionRelease(assertion) }
        sleepAssertions.removeAll()
    }
}

@available(macOS 15.0, *)
private final class TimeLapseCaptureOutput: NSObject, SCStreamOutput {
    let writer: TimeLapseWriter
    let index: Int

    init(writer: TimeLapseWriter, index: Int) { self.writer = writer; self.index = index }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            if index >= 0 { writer.ingest(sampleBuffer, source: index, kind: "video") }
        case .audio: writer.ingest(sampleBuffer, source: index, kind: "system")
        case .microphone: writer.ingest(sampleBuffer, source: index, kind: "microphone")
        @unknown default: break
        }
    }
}
