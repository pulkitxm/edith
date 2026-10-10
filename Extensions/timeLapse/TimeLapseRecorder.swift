import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import IOKit.pwr_mgt
import Observation
import ScreenCaptureKit

@available(macOS 15.0, *)
@MainActor @Observable
final class TimeLapseRecorder: NSObject, SCStreamDelegate {
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
    var playbackSeconds: Double = 0
    var lastDirectory: URL?
    var preview: CGImage?
    var sourceRevision = 0
    let sourceLoad = ContentLoad()
    let library: TimeLapseLibraryModel
    private var engineClient: ExtensionEngineClient?
    private var remoteRevision = 0
    private var permissionTask: Task<Void, Never>?
    private var receivedRemoteSettings = false
    @ObservationIgnored private var sourceSnapshot: TimeLapseSources?
    @ObservationIgnored private var thumbnailCache: [String: CGImage] = [:]
    private let thumbnailLoader = TimeLapseThumbnailLoader()
    private var previewConsumers: Set<UUID> = []
    var previewVisible: Bool { !previewConsumers.isEmpty }
    private var stopped = false
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var activeSession: UUID?
    private var streams: [SCStream] = []
    private var outputs: [TimeLapseCaptureOutput] = []
    private var writer: TimeLapseWriter?
    private var sleepAssertions: [IOPMAssertionID] = []

    override init() {
        library = TimeLapseLibraryModel()
        super.init()
    }

    init(engineClient: ExtensionEngineClient) {
        self.engineClient = engineClient
        library = TimeLapseLibraryModel(
            read: { _ in
                let data = try await engineClient.invoke("recording.ui.library")
                return try JSONDecoder().decode([TimeLapseRecording].self, from: data)
            },
            write: { recording, quality, destination in
                let payload = try JSONEncoder().encode(
                    TimeLapseUIExport(
                        id: recording.id, quality: quality, destination: destination.path))
                let data = try await engineClient.invoke("recording.ui.export", payload: payload)
                let job = try JSONDecoder().decode(TimeLapseUIExportStatus.self, from: data)
                let poll = try JSONEncoder().encode(["token": job.token])
                try await withTaskCancellationHandler {
                    while true {
                        try Task.checkCancellation()
                        let result = try await engineClient.invoke(
                            "recording.ui.exportPoll", payload: poll)
                        let status = try JSONDecoder().decode(
                            TimeLapseUIExportStatus.self, from: result)
                        guard status.token == job.token else {
                            throw ExtensionPeerError.invalidRequest
                        }
                        if status.complete {
                            if let error = status.error { throw ExtensionPeerError.rejected(error) }
                            return
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                } onCancel: {
                    Task { @MainActor in
                        _ = try? await engineClient.invoke(
                            "recording.ui.exportCancel", payload: poll)
                    }
                }
            })
        super.init()
    }

    func uiSnapshot() -> TimeLapseUISnapshot {
        .init(
            settings: settings, displays: displays, windows: windows, microphones: microphones,
            sourceMode: sourceMode, selectedDisplays: selectedDisplays,
            selectedWindows: selectedWindows,
            microphone: microphone, recording: recording, busy: busy, error: error,
            startedAt: startedAt,
            frames: frames, bytes: bytes, playbackSeconds: playbackSeconds,
            lastDirectory: lastDirectory,
            preview: preview.flatMap {
                NSBitmapImageRep(cgImage: $0).representation(
                    using: .jpeg, properties: [.compressionFactor: 0.75])
            },
            sourceRevision: sourceRevision, sourceError: sourceLoad.errorMessage,
            sourcesLoaded: sourceLoad.hasContent)
    }

    func refreshRemote() async {
        guard let engineClient, !stopped else { return }
        let revision = remoteRevision
        do {
            let payload = try JSONEncoder().encode(["preview": previewVisible])
            let data = try await engineClient.invoke("recording.ui.snapshot", payload: payload)
            guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
            applyRemote(try JSONDecoder().decode(TimeLapseUISnapshot.self, from: data))
        } catch is CancellationError {} catch {
            if !stopped { self.error = error.localizedDescription }
        }
    }

    private func applyRemote(_ value: TimeLapseUISnapshot) {
        if !receivedRemoteSettings || value.recording {
            settings = value.settings; sourceMode = value.sourceMode;
            selectedDisplays = value.selectedDisplays
            selectedWindows = value.selectedWindows; microphone = value.microphone
            receivedRemoteSettings = true
        }
        displays = value.displays; windows = value.windows; microphones = value.microphones
        recording = value.recording; busy = value.busy; error = value.error;
        startedAt = value.startedAt
        frames = value.frames; bytes = value.bytes; playbackSeconds = value.playbackSeconds
        lastDirectory = value.lastDirectory; sourceRevision = value.sourceRevision
        preview = value.preview.flatMap {
            NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let sourceError = value.sourceError {
            sourceLoad.fail(sourceLoad.begin(), message: sourceError)
        } else if value.sourcesLoaded {
            sourceLoad.setContent()
        }
    }

    var canStart: Bool {
        !stopped && !busy && !recording && !sourceLoad.isRunning
            && (sourceMode == "displays" ? !selectedDisplays.isEmpty : !selectedWindows.isEmpty)
    }

    static var libraryURL: URL {
        ExtensionData.root.appendingPathComponent("Recordings", isDirectory: true)
    }

    func loadSources(
        operation:
            @escaping @Sendable () async throws -> (TimeLapseSources, [TimeLapseMicrophoneChoice]) =
            {
                guard CGPreflightScreenCaptureAccess() else {
                    throw TimeLapseError.encoding(
                        "Allow Screen Recording in System Settings, then refresh sources.")
                }
                async let sources = TimeLapseSources.load()
                async let microphones = TimeLapseMicrophoneChoice.load()
                return try await (sources, microphones)
            }
    ) async {
        guard !stopped, !busy, !recording else { return }
        if let engineClient {
            await sourceLoad.perform(operation: {
                let data = try await engineClient.invoke("recording.ui.sources")
                return try JSONDecoder().decode(TimeLapseUISnapshot.self, from: data)
            }) { applyRemote($0) }
            return
        }
        await sourceLoad.perform(operation: operation) { [self] sources, microphones in
            sourceSnapshot = sources
            thumbnailCache.removeAll()
            sourceRevision += 1
            displays = sources.displayChoices
            windows = sources.windowChoices
            selectedDisplays.formIntersection(sources.displayIDs)
            selectedWindows.formIntersection(sources.windowIDs)
            if selectedDisplays.isEmpty, let first = displays.first {
                selectedDisplays.insert(first.id)
            }
            self.microphones = microphones
        }
    }

    func sourceThumbnail(mode: String, id: UInt32) async -> CGImage? {
        if let engineClient {
            guard !stopped else { return nil }
            do {
                let payload = try JSONEncoder().encode(TimeLapseUIThumbnail(mode: mode, id: id))
                let data = try await engineClient.invoke("recording.ui.thumbnail", payload: payload)
                let result = try JSONDecoder().decode(TimeLapseUIImage.self, from: data)
                guard !stopped, !Task.isCancelled else { return nil }
                return result.image.flatMap {
                    NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            } catch { return nil }
        }
        guard !stopped, !recording, let sources = sourceSnapshot else { return nil }
        let key = "\(mode)-\(id)"
        if let image = thumbnailCache[key] { return image }
        let revision = sourceRevision
        let image = await thumbnailLoader.load {
            await sources.thumbnail(mode: mode, id: id)
        }
        guard !stopped, !Task.isCancelled, !recording, revision == sourceRevision else {
            return nil
        }
        if let image {
            if thumbnailCache.count >= 32 { thumbnailCache.removeAll() }
            thumbnailCache[key] = image
        }
        return image
    }

    private func receivePreview(_ image: CGImage, session: UUID) {
        guard recording, previewVisible, activeSession == session else { return }
        preview = image
    }

    func showPreview(_ visible: Bool, consumer: UUID) {
        guard !stopped else { return }
        if visible { previewConsumers.insert(consumer) } else { previewConsumers.remove(consumer) }
        writer?.setPreviewEnabled(previewVisible)
    }

    func requestScreenPermission() {
        guard !stopped else { return }
        if let engineClient {
            permissionTask?.cancel()
            permissionTask = Task { _ = try? await engineClient.invoke("recording.ui.permission") }
        } else {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func start() async {
        guard canStart, startTask == nil else { return }
        if let engineClient {
            busy = true; remoteRevision += 1
            let revision = remoteRevision
            defer { if revision == remoteRevision { busy = false } }
            do {
                let payload = try JSONEncoder().encode(
                    TimeLapseUIStart(
                        settings: settings, sourceMode: sourceMode, displays: selectedDisplays,
                        windows: selectedWindows, microphone: microphone))
                let data = try await engineClient.invoke(
                    "recording.ui.start", payload: payload, timeout: 30)
                guard !stopped, !Task.isCancelled, revision == remoteRevision else { return }
                applyRemote(try JSONDecoder().decode(TimeLapseUISnapshot.self, from: data))
            } catch is CancellationError {} catch {
                if !stopped { self.error = error.localizedDescription }
            }
            return
        }
        let task = Task { await startRecording() }
        startTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        startTask = nil
    }

    private func startRecording() async {
        guard canStart else { return }
        busy = true
        error = nil
        preview = nil
        defer { busy = false }
        do {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let sources = try await TimeLapseSources.load()
            try Task.checkCancellation()
            let plan = try await sources.plan(
                mode: sourceMode, displays: selectedDisplays,
                windows: selectedWindows, settings: settings)
            try Task.checkCancellation()
            let filters = plan.filters
            let columns = plan.columns
            let rows = plan.rows
            let size = (width: plan.width, height: plan.height)
            let session = TimeLapseSession(
                settings: settings, width: size.width, height: size.height)
            activeSession = session.id
            let directory = Self.libraryURL.appendingPathComponent(
                session.id.uuidString, isDirectory: true)
            let writer = try TimeLapseWriter(
                directory: directory, session: session, sourceCount: filters.count,
                failure: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.activeSession == session.id else { return }
                        self.error = message
                        await self.stop(reason: message)
                    }
                },
                progress: { [weak self] frames, bytes, seconds in
                    Task { @MainActor in
                        guard let self, self.activeSession == session.id else { return }
                        self.frames = frames; self.bytes = bytes; self.playbackSeconds = seconds
                    }
                },
                preview: { [weak self] image in
                    await self?.receivePreview(image, session: session.id)
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
                    seconds: settings.captureInterval, preferredTimescale: 60000)
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
                try Task.checkCancellation()
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
                configuration.excludesCurrentProcessAudio = sourceMode == "displays"
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
                try Task.checkCancellation()
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
                        "Screen recording" as CFString,
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
            playbackSeconds = 0
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
            activeSession = nil
            releaseSleepAssertion()
        }
    }

    func stop(reason: String? = nil) async {
        if let engineClient {
            guard !stopped else { return }
            remoteRevision += 1
            do {
                let data = try await engineClient.invoke("recording.ui.stop", timeout: 30)
                guard !stopped, !Task.isCancelled else { return }
                applyRemote(try JSONDecoder().decode(TimeLapseUISnapshot.self, from: data))
            } catch is CancellationError {} catch {
                if !stopped { self.error = error.localizedDescription }
            }
            return
        }
        if let stopTask { await stopTask.value; return }
        guard !busy, writer != nil else { return }
        let task = Task { await stopRecording(reason: reason) }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func stopRecording(reason: String?) async {
        guard let writer else { return }
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
        frames = Int64(session.frames)
        playbackSeconds = session.playbackSeconds
        self.writer = nil
        activeSession = nil
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

    func shutdown() async {
        stopped = true
        permissionTask?.cancel()
        sourceLoad.cancel()
        startTask?.cancel()
        await startTask?.value
        if engineClient != nil {
            await library.shutdown(); await thumbnailLoader.shutdown(); thumbnailCache.removeAll();
            preview = nil
            return
        }
        await stop()
        await library.shutdown()
        sourceSnapshot = nil
        thumbnailCache.removeAll()
        displays = []
        windows = []
        microphones = []
        selectedDisplays = []
        selectedWindows = []
        previewConsumers.removeAll()
        preview = nil
        await thumbnailLoader.shutdown()
        releaseSleepAssertion()
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
