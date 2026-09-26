import AVFoundation
import AppKit
import EdithCameraSupport
import EdithCore
import EdithKit
import Foundation

struct VirtualCameraRunningApplication: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
}

struct VirtualCameraEngineEnvironment {
    var authorization: () -> AVAuthorizationStatus
    var obsRunning: () -> Bool
    var frontmostApplication: () -> VirtualCameraRunningApplication?

    static var live: VirtualCameraEngineEnvironment {
        VirtualCameraEngineEnvironment(
            authorization: { VirtualCameraDevices.authorization },
            obsRunning: {
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: VirtualCameraOBS.bundleIdentifier
                ).isEmpty
            },
            frontmostApplication: {
                NSWorkspace.shared.frontmostApplication.map {
                    VirtualCameraRunningApplication(
                        pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
                }
            })
    }
}

@MainActor
final class VirtualCameraEngine {
    static let idleGrace: TimeInterval = 3
    static let obsCooldown: TimeInterval = 1.5
    static let accessMessage = "Allow camera access for Edith"

    private let edithSink: VirtualCameraSink
    private let obsSink: VirtualCameraSink
    private let pipeline: VirtualCameraPipeline
    private let environment: VirtualCameraEngineEnvironment
    private var state: VirtualCameraState
    private var extensionStatus: VirtualCameraExtensionStatus?
    private var edithInstalled = false
    private var obsInstalled = false
    private(set) var route: VirtualCameraRoute?
    private(set) var streamingRoute: VirtualCameraRoute?
    private var stopWork: DispatchWorkItem?
    private var stateToken: NSObjectProtocol?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var lastPublished: VirtualCameraSnapshot?
    private var observedDevices: [Bool] = []
    private(set) var trigger: VirtualCameraRunningApplication?
    private var triggerQuit = false
    private var obsCooldownUntil = Date.distantPast
    private let previewBus: VirtualCameraPreviewBus

    var streaming: Bool { streamingRoute != nil }

    init(
        edithSink: VirtualCameraSink = VirtualCameraSink(
            extensionIdentifier: VirtualCameraIdentity.extensionIdentifier(
                forApplication: AppBuildIdentity.application)),
        obsSink: VirtualCameraSink = VirtualCameraSink(deviceUID: VirtualCameraOBS.deviceUID),
        state: VirtualCameraState = VirtualCameraStore.load(),
        environment: VirtualCameraEngineEnvironment = .live,
        previewBus: VirtualCameraPreviewBus = VirtualCameraPreviewBus()
    ) {
        self.edithSink = edithSink
        self.obsSink = obsSink
        self.state = state
        self.environment = environment
        self.previewBus = previewBus
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
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app =
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                MainActor.assumeIsolated { self?.applicationQuit(pid) }
            },
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExtension() }
            },
        ]
        observeDevices()
        refreshExtension()
    }

    func shutdown() {
        stopWork?.cancel()
        stopWork = nil
        if let stateToken { IPC.stopObserving(stateToken) }
        stateToken = nil
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens = []
        edithSink.stopObserving()
        obsSink.stopObserving()
        stopStreaming()
    }

    func syncSettings(_ announced: VirtualCameraState? = nil) {
        let next = announced ?? VirtualCameraStore.load()
        guard next != state else { return }
        let outputChanged = next.output != state.output
        state = next
        pipeline.update(state: effectiveState())
        if outputChanged { refreshExtension() } else { publishIfChanged() }
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
            enabled: true, helperRunning: true, extensionInstalled: edithInstalled,
            obsAvailable: obsInstalled, route: route, extensionBuild: extensionStatus?.build,
            clients: clients(), live: streaming, framesPerSecond: statistics.framesPerSecond,
            source: statistics.source ?? fallbackSource, sourceWidth: statistics.sourceWidth,
            sourceHeight: statistics.sourceHeight, sources: sources,
            format: route == .edithCamera ? extensionStatus?.format ?? .standard : .standard,
            cameraAccess: VirtualCameraClients.accessDescription(environment.authorization()),
            state: state, message: message)
    }

    private func clients() -> [VirtualCameraClient] {
        switch route {
        case .edithCamera:
            return VirtualCameraClients.clients(
                extensionStatus?.clients ?? [], resolver: Self.applicationName)
        case .obs:
            guard streamingRoute == .obs, let id = trigger?.bundleIdentifier else { return [] }
            return VirtualCameraClients.clients([id], resolver: Self.applicationName)
        case nil:
            return []
        }
    }

    static func applicationName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func effectiveState() -> VirtualCameraState {
        guard environment.authorization() != .authorized, state.privacy == .live else {
            return state
        }
        var gated = state
        gated.privacy = .card
        gated.privacyMessage = Self.accessMessage
        return gated
    }

    private func observeDevices() {
        observedDevices = [edithSink.isInstalled, obsSink.isInstalled]
        for sink in [edithSink, obsSink] {
            sink.observe { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refreshExtension() }
                }
            }
        }
    }

    func refreshExtension() {
        edithInstalled = edithSink.isInstalled
        obsInstalled = obsSink.isInstalled
        extensionStatus = edithInstalled ? edithSink.status() : nil
        if observedDevices != [edithInstalled, obsInstalled] { observeDevices() }
        route = VirtualCameraRoute.resolve(
            state.output, edithInstalled: edithInstalled, obsInstalled: obsInstalled)
        if let streamingRoute, streamingRoute != route { stopStreaming() }
        let format =
            route == .edithCamera
            ? extensionStatus?.format ?? .standard : VirtualCameraFormat.standard
        pipeline.update(
            outputSize: CGSize(width: format.width, height: format.height),
            frameRate: format.frameRate)
        evaluate()
        publishIfChanged()
    }

    func applicationQuit(_ pid: pid_t?) {
        guard let pid, trigger?.pid == pid else { return }
        triggerQuit = true
        evaluate()
        publishIfChanged()
    }

    private func evaluate() {
        switch route {
        case .edithCamera: evaluateEdithCamera()
        case .obs: evaluateOBS()
        case nil: if streaming { stopStreaming() }
        }
    }

    private func evaluateEdithCamera() {
        let demand = VirtualCameraDemand.next(
            installed: edithInstalled, inUse: extensionStatus?.isInUse == true,
            streaming: streaming, stopPending: stopWork != nil)
        switch demand {
        case .start, .keepStreaming:
            stopWork?.cancel()
            stopWork = nil
            if demand == .start { startStreaming(.edithCamera) }
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

    static func trigger(from application: VirtualCameraRunningApplication?)
        -> VirtualCameraRunningApplication?
    {
        guard let application,
            application.bundleIdentifier?.hasPrefix(VirtualCameraIdentity.productionApplication)
                != true
        else { return nil }
        return application
    }

    private func evaluateOBS() {
        let streamingOBS = streamingRoute == .obs
        let watching = !streamingOBS && Date() >= obsCooldownUntil && obsSink.isRunningSomewhere
        let demand = VirtualCameraOBSDemand.next(
            installed: obsInstalled, inUse: watching, streaming: streamingOBS,
            obsRunning: environment.obsRunning(), triggerQuit: triggerQuit)
        switch demand {
        case .start:
            let front = Self.trigger(from: environment.frontmostApplication())
            startStreaming(.obs)
            if streaming { trigger = front }
        case .stop:
            stopStreaming()
            obsCooldownUntil = Date().addingTimeInterval(Self.obsCooldown)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.obsCooldown + 0.1) {
                [weak self] in
                MainActor.assumeIsolated { self?.refreshExtension() }
            }
        case .keep, .idle:
            break
        }
    }

    private func startStreaming(_ target: VirtualCameraRoute) {
        let sink = target == .edithCamera ? edithSink : obsSink
        guard sink.connect() else { return }
        let frameRate =
            target == .edithCamera
            ? extensionStatus?.format.frameRate ?? VirtualCameraFormat.standard.frameRate
            : VirtualCameraFormat.standard.frameRate
        pipeline.update(state: effectiveState())
        let previewBus = previewBus
        pipeline.start { buffer in
            sink.send(buffer, frameRate: frameRate)
            previewBus.publish(buffer)
        }
        streamingRoute = target
        triggerQuit = false
    }

    private func stopStreaming() {
        guard let streamingRoute else { return }
        pipeline.stop()
        (streamingRoute == .edithCamera ? edithSink : obsSink).disconnect()
        self.streamingRoute = nil
        trigger = nil
        triggerQuit = false
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
