import AVFoundation
import AppKit
import EdithCameraSupport
import EdithCore
import EdithKit
import Foundation

@MainActor
final class VirtualCameraEngine {
    static let idleGrace: TimeInterval = 3
    static let accessMessage = "Allow camera access for Edith"

    private let sink: VirtualCameraSink
    private let pipeline: VirtualCameraPipeline
    private let authorization: () -> AVAuthorizationStatus
    private var state: VirtualCameraState
    private var extensionStatus: VirtualCameraExtensionStatus?
    private var installed = false
    private(set) var streaming = false
    private var stopWork: DispatchWorkItem?
    private var stateToken: NSObjectProtocol?
    private var lastPublished: VirtualCameraSnapshot?
    private var observedInstall = false

    init(
        sink: VirtualCameraSink = VirtualCameraSink(
            extensionIdentifier: VirtualCameraIdentity.extensionIdentifier(
                forApplication: AppBuildIdentity.application)),
        state: VirtualCameraState = VirtualCameraStore.load(),
        authorization: @escaping () -> AVAuthorizationStatus = {
            VirtualCameraDevices.authorization
        }
    ) {
        self.sink = sink
        self.state = state
        self.authorization = authorization
        let format = VirtualCameraFormat.standard
        pipeline = VirtualCameraPipeline(
            state: state, outputSize: CGSize(width: format.width, height: format.height),
            frameRate: format.frameRate)
    }

    func start() {
        stateToken = IPC.observe(
            IPC.Name.virtualCameraStateChanged,
            info: { [weak self] info in
                guard info[VirtualCameraIPC.originKey] as? String != "helper" else { return }
                let announced = VirtualCameraStore.announcedState(info)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.syncSettings(announced) }
                }
            })
        observeExtension()
        refreshExtension()
    }

    func shutdown() {
        stopWork?.cancel()
        stopWork = nil
        if let stateToken { IPC.stopObserving(stateToken) }
        stateToken = nil
        sink.stopObserving()
        stopStreaming()
    }

    func syncSettings(_ announced: VirtualCameraState? = nil) {
        let next = announced ?? VirtualCameraStore.load()
        guard next != state else { return }
        state = next
        pipeline.update(state: effectiveState())
        publishIfChanged()
    }

    func perform(_ request: VirtualCameraRequest) throws -> VirtualCameraSnapshot {
        guard request.changesState else { return snapshot() }
        var next = state
        let message = try VirtualCameraRequestReducer.apply(
            request, to: &next, sources: VirtualCameraDevices.sources())
        state = next.sanitized()
        VirtualCameraStore.save(state)
        VirtualCameraStore.announceChange(from: "helper", state: state)
        pipeline.update(state: effectiveState())
        publishIfChanged()
        return snapshot(message: message)
    }

    @discardableResult
    func togglePause() -> VirtualCameraPrivacy {
        let request: VirtualCameraRequest =
            state.privacy == .live ? .pause(.card, message: nil) : .resume
        _ = try? perform(request)
        return state.privacy
    }

    func snapshot(message: String? = nil) -> VirtualCameraSnapshot {
        let statistics = pipeline.statistics
        let sources = VirtualCameraDevices.sources()
        let fallbackSource = sources.first { $0.id == state.sourceID } ?? sources.first
        return VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: installed,
            extensionBuild: extensionStatus?.build,
            clients: VirtualCameraClients.clients(
                extensionStatus?.clients ?? [], resolver: Self.applicationName),
            live: streaming, framesPerSecond: statistics.framesPerSecond,
            source: statistics.source ?? fallbackSource, sourceWidth: statistics.sourceWidth,
            sourceHeight: statistics.sourceHeight, sources: sources,
            format: extensionStatus?.format ?? .standard,
            cameraAccess: VirtualCameraClients.accessDescription(authorization()), state: state,
            message: message)
    }

    static func applicationName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func effectiveState() -> VirtualCameraState {
        guard authorization() != .authorized, state.privacy == .live else { return state }
        var gated = state
        gated.privacy = .card
        gated.privacyMessage = Self.accessMessage
        return gated
    }

    private func observeExtension() {
        sink.observe { [weak self] in
            DispatchQueue.main.async { self?.refreshExtension() }
        }
    }

    func refreshExtension() {
        let wasInstalled = installed
        installed = sink.isInstalled
        extensionStatus = installed ? sink.status() : nil
        if installed != wasInstalled || (installed && !observedInstall) {
            observedInstall = installed
            observeExtension()
        }
        if let format = extensionStatus?.format {
            pipeline.update(
                outputSize: CGSize(width: format.width, height: format.height),
                frameRate: format.frameRate)
        }
        evaluate()
        publishIfChanged()
    }

    private func evaluate() {
        let demand = VirtualCameraDemand.next(
            installed: installed, inUse: extensionStatus?.isInUse == true, streaming: streaming,
            stopPending: stopWork != nil)
        switch demand {
        case .start, .keepStreaming:
            stopWork?.cancel()
            stopWork = nil
            if demand == .start { startStreaming() }
        case .scheduleStop:
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopWork = nil
                    guard self.extensionStatus?.isInUse != true else { return }
                    self.stopStreaming()
                    self.publishIfChanged()
                }
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleGrace, execute: work)
        case .waitForStop, .idle:
            break
        }
    }

    private func startStreaming() {
        guard sink.connect() else { return }
        let sink = sink
        let frameRate = extensionStatus?.format.frameRate ?? VirtualCameraFormat.standard.frameRate
        pipeline.update(state: effectiveState())
        pipeline.start { buffer in
            sink.send(buffer, frameRate: frameRate)
        }
        streaming = true
    }

    private func stopStreaming() {
        guard streaming else { return }
        pipeline.stop()
        sink.disconnect()
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
