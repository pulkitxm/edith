import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct VirtualCameraEngineEnvironment {
    var authorization: () -> AVAuthorizationStatus
    var sources: () -> [VirtualCameraSource] = { VirtualCameraDevices.sources() }

    static var live: VirtualCameraEngineEnvironment {
        VirtualCameraEngineEnvironment(authorization: { VirtualCameraDevices.authorization })
    }
}

@MainActor
final class VirtualCameraEngine {
    static let idleGrace: TimeInterval = 3
    static let accessMessage = "Allow camera access for Edith"

    private let edithSink: VirtualCameraSink
    private let pipeline: VirtualCameraPipeline
    private let environment: VirtualCameraEngineEnvironment
    private var state: VirtualCameraState
    private var extensionStatus: VirtualCameraExtensionStatus?
    private var edithInstalled = false
    private(set) var streaming = false
    private var stopWork: DispatchWorkItem?
    private let stopWorkReturns = DispatchGroup()
    private let callbacks = VirtualCameraEngineCallbacks()
    private var draining = false
    private var shutdownTask: Task<Void, Never>?
    private var stateToken: NSObjectProtocol?
    private var lastPublished: VirtualCameraSnapshot?
    private var observing = false
    private let previewBus: VirtualCameraPreviewBus
    private var recordingPath: String?
    private var recordingFinishing = false
    private(set) var isStopped = false
    private var recordingShutdown: Task<Void, Never>?

    init(
        edithSink: VirtualCameraSink = VirtualCameraSink(
            extensionIdentifier: VirtualCameraIdentity.extensionIdentifier(
                forApplication: AppBuildIdentity.application)),
        state: VirtualCameraState = VirtualCameraStore.load(),
        environment: VirtualCameraEngineEnvironment = .live,
        previewBus: VirtualCameraPreviewBus = VirtualCameraPreviewBus()
    ) {
        self.edithSink = edithSink
        self.state = state
        self.environment = environment
        self.previewBus = previewBus
        let format = VirtualCameraFormat.standard
        pipeline = VirtualCameraPipeline(
            state: state, outputSize: CGSize(width: format.width, height: format.height),
            frameRate: format.frameRate)
    }

    func start() {
        guard !isStopped, !draining, stateToken == nil else { return }
        let callbacks = callbacks
        stateToken = IPC.observe(
            IPC.Name.virtualCameraStateChanged,
            info: { [weak self] info in
                guard info[VirtualCameraIPC.originKey] as? String != "helper" else { return }
                callbacks.perform {
                    let announced = VirtualCameraStore.announcedState(info)
                    callbacks.submit { [weak self] in self?.syncSettings(announced) }
                }
            })
        observeDevices()
        refreshExtension()
    }

    func beginSuspension() {
        guard !draining else { return }
        draining = true
        callbacks.close()
        stopWork?.cancel()
        if let stateToken { IPC.stopObserving(stateToken) }
        stateToken = nil
        edithSink.stopObserving()
    }

    func shutdown() {
        beginSuspension()
        guard !isStopped else { return }
        isStopped = true
        if recordingPath != nil {
            recordingShutdown = Task { [pipeline] in _ = try? await pipeline.stopRecording() }
            recordingPath = nil
        }
        stopStreaming()
    }

    func finishShutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        shutdown()
        let recording = recordingShutdown
        let task = Task { [self, recording] in
            await recording?.value
            await callbacks.wait()
            await withCheckedContinuation { continuation in
                stopWorkReturns.notify(queue: .main) { continuation.resume() }
            }
            await pipeline.stopAndDrain()
            recordingShutdown = nil
            stopWork = nil
            previewBus.close()
        }
        shutdownTask = task
        await task.value
    }

    func syncSettings(_ announced: VirtualCameraState? = nil) {
        guard !isStopped, !draining else { return }
        let next = announced ?? VirtualCameraStore.load()
        guard next != state else { return }
        state = next
        pipeline.update(state: effectiveState())
        evaluate()
        publishIfChanged()
    }

    func previewComposition(_ composition: VirtualCameraComposition) {
        guard !isStopped, !draining else { return }
        var shadow = effectiveState()
        shadow.composition = composition
        pipeline.update(state: shadow.sanitized())
    }

    func perform(_ request: VirtualCameraRequest) throws -> VirtualCameraSnapshot {
        guard !isStopped, !draining else { throw ExtensionPeerError.unavailable }
        guard request.changesState else { return snapshot() }
        if case .pause(.stopped, _) = request, recordingPath != nil {
            throw NSError(
                domain: "MeetingRecording", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Stop the recording before stopping the camera."
                ])
        }
        if request == .retry { stopStreaming() }
        var next = state
        let message = try VirtualCameraRequestReducer.apply(
            request, to: &next, sources: environment.sources())
        state = next.sanitized()
        VirtualCameraStore.save(state)
        VirtualCameraStore.announceChange(from: "helper", state: state)
        pipeline.update(state: effectiveState())
        evaluate()
        publishIfChanged()
        return snapshot(message: message)
    }

    @discardableResult
    func togglePause() -> VirtualCameraPrivacy {
        guard state.privacy != .stopped else { return .stopped }
        let request: VirtualCameraRequest =
            state.privacy == .live ? .pause(.card, message: nil) : .resume
        _ = try? perform(request)
        return state.privacy
    }

    func performRecording(_ request: VirtualCameraRequest) async throws -> VirtualCameraSnapshot {
        guard !isStopped, !draining else { throw ExtensionPeerError.unavailable }
        guard !recordingFinishing else { throw CocoaError(.fileWriteUnknown) }
        switch request {
        case .screenSources:
            var result = snapshot()
            result.screenSources = try await VirtualCameraScreenCatalog.sources()
            return result
        case .recordStart(let path):
            guard recordingPath == nil else { throw CocoaError(.fileWriteFileExists) }
            guard state.privacy != .stopped else {
                throw NSError(
                    domain: "MeetingRecording", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Choose Live before recording."])
            }
            try pipeline.startRecording(to: URL(fileURLWithPath: path))
            recordingPath = path
            if !streaming { startRecordingPreview() }
            publishIfChanged()
            return snapshot(message: "Recording started.")
        case .recordStop:
            guard recordingPath != nil else { throw CocoaError(.fileNoSuchFile) }
            recordingFinishing = true
            defer {
                recordingFinishing = false
                recordingPath = nil
                if !streaming { pipeline.stop() }
                publishIfChanged()
            }
            let url = try await pipeline.stopRecording()
            recordingPath = nil
            return snapshot(message: "Saved \(url.path)")
        default:
            return try perform(request)
        }
    }

    private func startRecordingPreview() {
        pipeline.update(state: effectiveState())
        let bus = previewBus
        pipeline.start { buffer in bus.publish(buffer) }
    }

    func snapshot(message: String? = nil) -> VirtualCameraSnapshot {
        let statistics = pipeline.statistics
        let sources = environment.sources()
        let fallbackSource = sources.first { $0.id == state.sourceID } ?? sources.first
        return VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: edithInstalled,
            extensionBuild: extensionStatus?.build,
            clients: VirtualCameraClients.clients(
                extensionStatus?.clients ?? [], resolver: Self.applicationName),
            live: streaming, framesPerSecond: statistics.framesPerSecond,
            source: statistics.source ?? fallbackSource, sourceWidth: statistics.sourceWidth,
            sourceHeight: statistics.sourceHeight, sources: sources,
            format: extensionStatus?.format ?? .standard,
            cameraAccess: VirtualCameraClients.accessDescription(environment.authorization()),
            systemBackgroundActive: statistics.systemBackgroundActive,
            state: state, message: message, recordingPath: recordingPath)
    }

    static func applicationName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func effectiveState() -> VirtualCameraState {
        guard state.media.kind == .camera, environment.authorization() != .authorized,
            state.privacy == .live
        else {
            return state
        }
        var gated = state
        gated.privacy = .card
        gated.privacyMessage = Self.accessMessage
        return gated
    }

    private func observeDevices() {
        observing = edithSink.isInstalled
        let callbacks = callbacks
        edithSink.observe { [weak self] in
            callbacks.perform {
                callbacks.submit { [weak self] in self?.refreshExtension() }
            }
        }
    }

    func refreshExtension() {
        guard !isStopped, !draining else { return }
        edithInstalled = edithSink.isInstalled
        extensionStatus = edithInstalled ? edithSink.status() : nil
        if observing != edithInstalled { observeDevices() }
        if streaming, !edithInstalled { stopStreaming() }
        let format = extensionStatus?.format ?? .standard
        pipeline.update(
            outputSize: CGSize(width: format.width, height: format.height),
            frameRate: format.frameRate)
        evaluate()
        publishIfChanged()
    }

    private func evaluate() {
        guard !isStopped, !draining else { return }
        guard state.privacy != .stopped else {
            stopWork?.cancel()
            stopWork = nil
            stopStreaming()
            return
        }
        let demand = VirtualCameraDemand.next(
            installed: edithInstalled, inUse: extensionStatus?.isInUse == true,
            streaming: streaming, stopPending: stopWork != nil)
        switch demand {
        case .start, .keepStreaming:
            stopWork?.cancel()
            stopWork = nil
            if demand == .start { startStreaming() }
        case .scheduleStop:
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isStopped, !self.draining else { return }
                    self.stopWork = nil
                    guard self.extensionStatus?.isInUse != true else { return }
                    self.stopStreaming()
                    self.publishIfChanged()
                }
            }
            stopWorkReturns.enter()
            let returns = stopWorkReturns
            work.notify(queue: .main) { returns.leave() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleGrace, execute: work)
        case .waitForStop, .idle:
            break
        }
    }

    private func startStreaming() {
        let sink = edithSink
        guard sink.connect() else { return }
        let frameRate = extensionStatus?.format.frameRate ?? VirtualCameraFormat.standard.frameRate
        pipeline.update(state: effectiveState())
        let previewBus = previewBus
        let pipeline = pipeline
        pipeline.start { [weak pipeline] buffer in
            sink.send(buffer, frameRate: frameRate)
            previewBus.publish(buffer, reference: pipeline?.reference)
        }
        streaming = true
    }

    private func stopStreaming() {
        guard streaming else { return }
        if recordingPath == nil { pipeline.stop() } else { startRecordingPreview() }
        edithSink.disconnect()
        streaming = false
    }

    private func publishIfChanged() {
        var current = snapshot()
        current.framesPerSecond = 0
        guard current != lastPublished else { return }
        lastPublished = current
        guard let encoded = current.encoded else { return }
        IPC.post(
            IPC.Name.virtualCameraStatusChanged, userInfo: [VirtualCameraIPC.snapshotKey: encoded])
    }
}

private final class VirtualCameraEngineCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private let pending = DispatchGroup()
    private var closed = false

    func perform(_ operation: () -> Void) {
        let admitted = lock.withLock {
            guard !closed else { return false }
            pending.enter()
            return true
        }
        guard admitted else { return }
        defer { pending.leave() }
        operation()
    }

    func submit(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock {
            guard !closed else { return }
            pending.enter()
            DispatchQueue.main.async { [self] in
                defer { pending.leave() }
                operation()
            }
        }
    }

    func close() { lock.withLock { closed = true } }

    func wait() async {
        await withCheckedContinuation { continuation in
            pending.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}
