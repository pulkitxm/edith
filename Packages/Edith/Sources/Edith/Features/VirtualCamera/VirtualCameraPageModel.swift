import AVFoundation
import AppKit
import EdithCameraSupport
import EdithKit
import Foundation
import UniformTypeIdentifiers

enum VirtualCameraInspectorTab: String, CaseIterable, Identifiable {
    case frame
    case look
    case background
    case overlays
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frame: "Frame"
        case .look: "Look"
        case .background: "Background"
        case .overlays: "Overlays"
        case .output: "Output"
        }
    }

    var symbolName: String {
        switch self {
        case .frame: "crop"
        case .look: "camera.filters"
        case .background: "person.crop.rectangle"
        case .overlays: "text.below.photo"
        case .output: "video.badge.checkmark"
        }
    }
}

enum VirtualCameraImageTarget {
    case logo
    case background
}

@MainActor
final class VirtualCameraPageModel: ObservableObject {
    static let previewSize = CGSize(width: 1280, height: 720)
    static let saveDelay: TimeInterval = 0.15

    @Published private(set) var state: VirtualCameraState
    @Published private(set) var snapshot: VirtualCameraSnapshot?
    @Published private(set) var helperReachable = true
    @Published private(set) var statusPending = false
    @Published private(set) var sources: [VirtualCameraSource] = []
    @Published private(set) var previewStatistics = VirtualCameraPipeline.Statistics()
    @Published private(set) var cameraAccess: AVAuthorizationStatus
    @Published private(set) var previewRunning = false
    @Published var tab: VirtualCameraInspectorTab = .frame {
        didSet {
            guard tab == .look, let reference = pipeline.reference, reference !== thumbnailSource
            else { return }
            updateLookThumbnails(from: reference)
        }
    }
    @Published var showsGrid = false
    @Published private(set) var lookThumbnails: [VirtualCameraLookPreset: CGImage] = [:]
    @Published var errorMessage: String?

    let display = VirtualCameraPreviewDisplay()
    let extensionManager: VirtualCameraExtensionManager
    private let defaults: UserDefaults
    private let pipeline: VirtualCameraPipeline
    private let accessProvider: () -> AVAuthorizationStatus
    private let sourceProvider: () -> [VirtualCameraSource]
    private let previewBus: VirtualCameraPreviewBus
    private var saveWork: DispatchWorkItem?
    private var statusToken: NSObjectProtocol?
    private var stateToken: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var helperPreviewTimer: DispatchSourceTimer?
    private var visible = false
    private var ticks = 0
    private var previewFeed: PreviewFeed = .idle
    private var thumbnailSource: CGImage?
    private static let thumbnailRenderer = VirtualCameraRenderer()

    init(
        defaults: UserDefaults = SharedDefaults.store,
        pipeline: VirtualCameraPipeline? = nil,
        extensionManager: VirtualCameraExtensionManager? = nil,
        accessProvider: @escaping () -> AVAuthorizationStatus = {
            VirtualCameraDevices.authorization
        },
        sourceProvider: @escaping () -> [VirtualCameraSource] = { VirtualCameraDevices.sources() },
        previewBus: VirtualCameraPreviewBus = VirtualCameraPreviewBus()
    ) {
        let state = VirtualCameraStore.load(defaults)
        self.defaults = defaults
        self.state = state
        self.pipeline =
            pipeline ?? VirtualCameraPipeline(state: state, outputSize: Self.previewSize)
        self.extensionManager = extensionManager ?? VirtualCameraExtensionManager()
        self.accessProvider = accessProvider
        self.sourceProvider = sourceProvider
        self.previewBus = previewBus
        self.cameraAccess = accessProvider()
    }

    private enum PreviewFeed {
        case idle
        case local
        case helper
    }

    var showsHelperPreview: Bool { previewFeed == .helper }

    var composition: VirtualCameraComposition { state.composition }

    var sourceSize: CGSize {
        let width = previewStatistics.sourceWidth > 0 ? previewStatistics.sourceWidth : 1920
        let height = previewStatistics.sourceHeight > 0 ? previewStatistics.sourceHeight : 1080
        return VirtualCameraGeometry.orientedSize(
            CGSize(width: width, height: height),
            quarterTurns: state.composition.framing.quarterTurns)
    }

    var outputSize: CGSize {
        let format = snapshot?.format ?? .standard
        return CGSize(width: format.width, height: format.height)
    }

    var selectedSource: VirtualCameraSource? {
        sources.first { $0.id == state.sourceID } ?? sources.first
    }

    static let statusRefreshTicks = 5

    var statusHeadline: String {
        if let snapshot, helperReachable { return snapshot.headline }
        if statusPending || helperReachable { return "Checking Edith Bar" }
        return "Edith Bar is not answering"
    }

    var isLive: Bool { snapshot?.live == true }

    func appear() {
        guard !visible else { return }
        visible = true
        previewBus.setWanted(true)
        if saveWork != nil { flushSave() } else { reloadState() }
        refreshSources()
        extensionManager.refreshDetached()
        statusToken = IPC.observe(
            IPC.Name.virtualCameraStatusChanged,
            info: { [weak self] info in
                let decoded = VirtualCameraSnapshot.decode(
                    info[VirtualCameraIPC.snapshotKey] as? String)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(decoded) }
                }
            })
        stateToken = IPC.observe(
            IPC.Name.virtualCameraStateChanged,
            info: { [weak self] info in
                guard info[VirtualCameraIPC.originKey] as? String == "helper" else { return }
                let announced = VirtualCameraStore.announcedState(info)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reloadState(announced) }
                }
            })
        requestStatus()
        syncPreviewFeed()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    func disappear() {
        guard visible else { return }
        visible = false
        previewBus.setWanted(false)
        flushSave()
        statusTask?.cancel()
        statusTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        if let statusToken { IPC.stopObserving(statusToken) }
        if let stateToken { IPC.stopObserving(stateToken) }
        statusToken = nil
        stateToken = nil
        stopPreview()
    }

    private func tick() {
        ticks += 1
        if ticks % Self.statusRefreshTicks == 0 || (!helperReachable && !statusPending) {
            requestStatus()
            extensionManager.refreshDetached()
        }
        let statistics = pipeline.statistics
        if statistics.sourceWidth != previewStatistics.sourceWidth
            || statistics.sourceHeight != previewStatistics.sourceHeight
            || statistics.source != previewStatistics.source
        {
            previewStatistics = statistics
        }
        if tab == .look, let reference = pipeline.reference, reference !== thumbnailSource {
            updateLookThumbnails(from: reference)
        }
        let access = accessProvider()
        if access != cameraAccess {
            cameraAccess = access
            if access == .authorized { syncPreviewFeed() }
        }
    }

    func updateLookThumbnails(from reference: CGImage) {
        thumbnailSource = reference
        lookThumbnails = VirtualCameraLooks.thumbnails(
            from: reference, renderer: Self.thumbnailRenderer)
    }

    var previewReference: CGImage? { pipeline.reference }

    func receive(_ decoded: VirtualCameraSnapshot?) {
        guard let decoded else { return }
        snapshot = decoded
        helperReachable = true
        if visible { syncPreviewFeed() }
    }

    func requestStatus() {
        statusTask?.cancel()
        statusPending = true
        statusTask = Task { [weak self] in
            do {
                let snapshot = try await VirtualCameraOperationExecution.request(
                    .status, timeout: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.statusPending = false
                self?.receive(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.statusPending = false
                self?.helperReachable = false
            }
        }
    }

    func reloadState(_ announced: VirtualCameraState? = nil) {
        let stored = announced ?? VirtualCameraStore.load(defaults)
        guard stored != state else { return }
        state = stored
        pipeline.update(state: stored)
    }

    func refreshSources() {
        sources = sourceProvider()
    }

    func syncPreviewFeed() {
        guard visible else { return }
        if snapshot?.live == true {
            showHelperPreview()
        } else {
            hideHelperPreview()
            startLocalPreview()
        }
    }

    private func showHelperPreview() {
        if previewFeed == .local { pipeline.stop() }
        previewFeed = .helper
        previewRunning = true
        guard helperPreviewTimer == nil else { return }
        let bus = previewBus
        let display = display
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler {
            guard let buffer = bus.latest() else { return }
            display.push(buffer)
        }
        timer.resume()
        helperPreviewTimer = timer
    }

    private func hideHelperPreview() {
        helperPreviewTimer?.cancel()
        helperPreviewTimer = nil
        guard previewFeed == .helper else { return }
        previewFeed = .idle
        previewRunning = false
    }

    private func startLocalPreview() {
        cameraAccess = accessProvider()
        guard visible, cameraAccess == .authorized, previewFeed != .local else { return }
        hideHelperPreview()
        let display = display
        pipeline.update(state: state)
        pipeline.start { buffer in display.push(buffer) }
        previewFeed = .local
        previewRunning = true
    }

    func stopPreview() {
        hideHelperPreview()
        guard previewFeed == .local || previewRunning else { return }
        if previewFeed == .local { pipeline.stop() }
        previewFeed = .idle
        previewRunning = false
    }

    func requestCameraAccess() {
        guard cameraAccess == .notDetermined else {
            do {
                _ = try MainPermissionOperations.center.openSettings(for: .camera)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cameraAccess = self.accessProvider()
                    self.syncPreviewFeed()
                    self.refreshSources()
                }
            }
        }
    }

    func update(_ change: (inout VirtualCameraState) -> Void) {
        var next = state
        change(&next)
        next = next.sanitized()
        guard next != state else { return }
        state = next
        pipeline.update(state: next)
        scheduleSave()
    }

    func updateComposition(_ change: (inout VirtualCameraComposition) -> Void) {
        update { change(&$0.composition) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard VirtualCameraStore.load(defaults) != state else { return }
        VirtualCameraStore.save(state, to: defaults)
        VirtualCameraStore.announceChange(from: "window", state: state)
    }

    func pan(by translation: CGSize, in viewSize: CGSize) {
        updateComposition {
            $0.framing = VirtualCameraGeometry.panned(
                $0.framing, by: translation, viewSize: viewSize, source: sourceSize,
                output: outputSize)
        }
    }

    func zoom(by factor: Double, anchor: CGPoint) {
        updateComposition {
            $0.framing = VirtualCameraGeometry.zoomed(
                $0.framing, by: factor, anchor: anchor, source: sourceSize, output: outputSize)
        }
    }

    func setZoom(_ zoom: Double) {
        updateComposition {
            var framing = $0.framing
            framing.zoom = zoom
            $0.framing = VirtualCameraGeometry.clamped(
                framing, source: sourceSize, output: outputSize)
        }
    }

    func resetFraming() {
        updateComposition {
            let auto = $0.framing.autoFrame
            $0.framing = VirtualCameraFraming(autoFrame: auto)
        }
    }

    func rotate(clockwise: Bool) {
        updateComposition { $0.framing.quarterTurns += clockwise ? 1 : 3 }
    }

    func selectSource(_ source: VirtualCameraSource) {
        update { $0.sourceID = source.id }
    }

    func apply(_ scene: VirtualCameraScene) {
        update { state in
            _ = try? VirtualCameraSceneLibrary.apply(scene.id.uuidString, in: &state)
        }
    }

    func saveScene(named name: String) {
        do {
            var next = state
            _ = try VirtualCameraSceneLibrary.save(name, in: &next)
            update { $0 = next }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateScene(_ scene: VirtualCameraScene) {
        perform { try VirtualCameraSceneLibrary.update(scene.id, in: &$0) }
    }

    func renameScene(_ scene: VirtualCameraScene, to name: String) {
        perform { try VirtualCameraSceneLibrary.rename(scene.id, to: name, in: &$0) }
    }

    func duplicateScene(_ scene: VirtualCameraScene) {
        perform { _ = try VirtualCameraSceneLibrary.duplicate(scene.id, in: &$0) }
    }

    func deleteScene(_ scene: VirtualCameraScene) {
        perform { try VirtualCameraSceneLibrary.delete(scene.id, in: &$0) }
    }

    func moveScene(_ scene: VirtualCameraScene, by offset: Int) {
        update { VirtualCameraSceneLibrary.move(scene.id, by: offset, in: &$0) }
    }

    func suggestedSceneName() -> String {
        VirtualCameraSceneLibrary.uniqueName("Scene", in: state.scenes)
    }

    private func perform(_ body: (inout VirtualCameraState) throws -> Void) {
        do {
            var next = state
            try body(&next)
            update { $0 = next }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pause(_ mode: VirtualCameraPrivacy) {
        update { $0.privacy = mode }
    }

    func resume() {
        update { $0.privacy = .live }
    }

    func chooseImage(for target: VirtualCameraImageTarget) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = target == .logo ? "Choose a logo" : "Choose a background image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url, for: target)
    }

    func importImage(_ url: URL, for target: VirtualCameraImageTarget) {
        do {
            let stored = try VirtualCameraStore.importAsset(from: url)
            updateComposition {
                switch target {
                case .logo:
                    $0.overlays.logo.imagePath = stored.path
                    $0.overlays.logo.enabled = true
                case .background:
                    $0.background.imagePath = stored.path
                    $0.background.mode = .image
                }
            }
            VirtualCameraStore.pruneAssets(keeping: state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeImage(for target: VirtualCameraImageTarget) {
        updateComposition {
            switch target {
            case .logo:
                $0.overlays.logo.imagePath = nil
                $0.overlays.logo.enabled = false
            case .background:
                $0.background.imagePath = nil
                if $0.background.mode == .image { $0.background.mode = .none }
            }
        }
        flushSave()
        VirtualCameraStore.pruneAssets(keeping: state)
    }

    func showPreviewFrame(_ buffer: CVPixelBuffer) {
        display.push(buffer)
        display.flush()
    }

    func renderPreview(from pixelBuffer: CVPixelBuffer, at time: TimeInterval = 1) {
        pipeline.update(state: state)
        guard let rendered = pipeline.process(pixelBuffer, at: time) else { return }
        showPreviewFrame(rendered)
    }

    func injectForTesting(snapshot: VirtualCameraSnapshot?, sources: [VirtualCameraSource]) {
        self.snapshot = snapshot
        self.sources = sources
        helperReachable = snapshot != nil
    }
}
