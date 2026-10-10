import AVFoundation
import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VirtualCameraInspectorTab: String, CaseIterable, Identifiable {
    case audio
    case voice
    case devices
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
        case .audio: "Sounds"
        case .voice: "Voice"
        case .devices: "Audio devices"
        }
    }

    var symbolName: String {
        switch self {
        case .frame: "crop"
        case .look: "camera.filters"
        case .background: "person.crop.rectangle"
        case .overlays: "text.below.photo"
        case .output: "video.badge.checkmark"
        case .audio: "waveform"
        case .voice: "person.wave.2"
        case .devices: "mic"
        }
    }
}

enum VirtualCameraImageTarget {
    case logo
    case background
}

@MainActor
final class VirtualCameraPageModel: ObservableObject {
    static let shared = VirtualCameraPageModel()
    static let previewSize = CGSize(width: 1280, height: 720)
    static let saveDelay: TimeInterval = 0.15

    @Published private(set) var state: VirtualCameraState
    @Published private(set) var snapshot: VirtualCameraSnapshot?
    @Published private(set) var helperReachable = true
    @Published private(set) var statusPending = false
    @Published private(set) var sources: [VirtualCameraSource] = []
    @Published private(set) var sourcesLoaded = false
    @Published private(set) var hasPreviewFrame = false
    @Published private(set) var previewStatistics = VirtualCameraPipeline.Statistics()
    @Published private(set) var cameraAccess: AVAuthorizationStatus
    @Published private(set) var previewRunning = false
    @Published private(set) var previewFailure: String?
    @Published var tab: VirtualCameraInspectorTab = .frame {
        didSet {
            defaults.set(tab.rawValue, forKey: "virtualCameraInspectorSection")
            expandedInspectorSections.insert(tab)
            guard tab == .look, let reference = previewReference, reference !== thumbnailSource
            else { return }
            updateLookThumbnails(from: reference)
        }
    }
    @Published private(set) var expandedInspectorSections: Set<VirtualCameraInspectorTab> = [.audio]
    {
        didSet {
            var storedSections: [String] = []
            for section in VirtualCameraInspectorTab.allCases
            where expandedInspectorSections.contains(section) {
                storedSections.append(section.rawValue)
            }
            defaults.set(storedSections, forKey: "virtualCameraInspectorExpandedSections")
        }
    }
    @Published var showsGrid = false
    @Published private(set) var lookThumbnails: [VirtualCameraLookPreset: CGImage] = [:]
    @Published var errorMessage: String?
    @Published var audioPending = false

    let display = VirtualCameraPreviewDisplay()
    let extensionManager: VirtualCameraExtensionManager
    private let defaults: UserDefaults
    private var engineClient: ExtensionEngineClient?
    private var stopped = false
    private var remotePoll: Task<Void, Never>?
    private var localRequests: [UUID: Task<Void, Never>] = [:]
    private let requestHandler: ((VirtualCameraRequest) async throws -> VirtualCameraSnapshot)?
    private var pipeline: VirtualCameraPipeline?
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0
    private var sourceTask: Task<Void, Never>?
    private let accessProvider: () -> AVAuthorizationStatus
    private let clock: () -> TimeInterval
    private let sourceProvider: (() -> [VirtualCameraSource])?
    private let previewBus: VirtualCameraPreviewBus
    private let previewBusQueue = DispatchQueue(
        label: "com.pulkit.edith.camera.preview-demand", qos: .utility)
    private var saveTimer: Timer?
    private var awaitingHelperState: VirtualCameraState?
    private var statusToken: NSObjectProtocol?
    private var stateToken: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?
    private var statsTimer: Timer?
    private var helperPreviewTimer: DispatchSourceTimer?
    private var visible = false
    private var attachments = 0
    private var ticks = 0
    private var previewFeed: PreviewFeed = .idle
    private var thumbnailSource: CGImage?
    private var helperReference: CGImage?
    private var previewStartedAt: TimeInterval?
    private var thumbnailTask: Task<Void, Never>?
    nonisolated private static let thumbnailRenderer = VirtualCameraRenderer()

    init(
        defaults: UserDefaults = SharedDefaults.store,
        pipeline: VirtualCameraPipeline? = nil,
        extensionManager: VirtualCameraExtensionManager? = nil,
        accessProvider: @escaping () -> AVAuthorizationStatus = {
            VirtualCameraDevices.authorization
        },
        sourceProvider: (() -> [VirtualCameraSource])? = nil,
        previewBus: VirtualCameraPreviewBus = VirtualCameraPreviewBus(),
        requestHandler: ((VirtualCameraRequest) async throws -> VirtualCameraSnapshot)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let state = VirtualCameraStore.load(defaults)
        var restoredSections: Set<VirtualCameraInspectorTab> = [.audio]
        if let storedSections = defaults.stringArray(
            forKey: "virtualCameraInspectorExpandedSections")
        {
            restoredSections = []
            for value in storedSections {
                if let section = VirtualCameraInspectorTab(rawValue: value) {
                    restoredSections.insert(section)
                }
            }
        }
        self.defaults = defaults
        self.state = state
        self.pipeline = pipeline
        self.extensionManager = extensionManager ?? VirtualCameraExtensionManager()
        self.accessProvider = accessProvider
        self.clock = clock
        self.requestHandler = requestHandler
        self.sourceProvider = sourceProvider
        self.previewBus = previewBus
        self.cameraAccess = accessProvider()
        self.tab =
            VirtualCameraInspectorTab(
                rawValue: defaults.string(forKey: "virtualCameraInspectorSection") ?? "audio")
            ?? .audio
        self.expandedInspectorSections = restoredSections
        display.onAvailabilityChanged = { [weak self] available in
            self?.hasPreviewFrame = available
            if available {
                self?.previewFailure = nil
                self?.previewStartedAt = nil
            }
        }
    }

    convenience init(engineClient: ExtensionEngineClient, defaults: UserDefaults) {
        self.init(
            defaults: defaults,
            extensionManager: VirtualCameraExtensionManager(
                environment: .init(
                    bundleURL: Bundle.main.bundleURL, hasInstallEntitlement: { false },
                    deviceVisible: { false })), accessProvider: { .denied }, sourceProvider: { [] })
        self.engineClient = engineClient
    }

    func performRequest(_ request: VirtualCameraRequest, timeout: Duration = .seconds(30))
        async throws -> VirtualCameraSnapshot
    {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let engineClient {
            let runtime = VirtualCameraRuntimeRequest(
                request: request, deadline: Date().addingTimeInterval(30))
            guard let input = runtime.payload else { throw ExtensionPeerError.invalidRequest }
            let data = try await engineClient.invoke(
                "camera.request", payload: JSONSerialization.data(withJSONObject: input),
                timeout: 30)
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try JSONDecoder().decode(VirtualCameraSnapshot.self, from: data)
        }
        if let requestHandler { return try await requestHandler(request) }
        return try await VirtualCameraOperationExecution.request(request, timeout: timeout)
    }

    func runAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        localRequests[id] = Task { [weak self] in
            defer { self?.localRequests[id] = nil }
            do { try await action() } catch is CancellationError {} catch {
                guard let self, !stopped else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadAudioDevices() async -> [MeetingAudioDevice] {
        if let engineClient {
            guard let data = try? await engineClient.invoke("camera.ui.devices"), !stopped,
                !Task.isCancelled
            else { return [] }
            return (try? JSONDecoder().decode([MeetingAudioDevice].self, from: data)) ?? []
        }
        return await Task.detached { MeetingAudioDevices.list() }.value
    }

    func makeScreenCatalog() -> ScreenCaptureSourceCatalog {
        ScreenCaptureSourceCatalog(engineClient: engineClient)
    }

    func assetThumbnail(_ url: URL) async -> NSImage? {
        if let engineClient {
            guard let payload = try? JSONEncoder().encode(["path": url.path]),
                let data = try? await engineClient.invoke("camera.ui.asset", payload: payload),
                !stopped, !Task.isCancelled,
                let image = try? JSONDecoder().decode(CameraUIImage.self, from: data)
            else { return nil }
            return image.image.flatMap(NSImage.init(data:))
        }
        return await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                    ] as CFDictionary)
            else { return nil as NSImage? }
            return NSImage(cgImage: image, size: .zero)
        }.value
    }

    func refreshRemote() async {
        guard let engineClient, !stopped else { return }
        do {
            let data = try await engineClient.invoke("camera.ui.snapshot")
            let value = try JSONDecoder().decode(CameraUISnapshot.self, from: data)
            guard !stopped, !Task.isCancelled else { return }
            snapshot = value.snapshot; helperReachable = true; statusPending = false
            if saveTimer == nil
                && (awaitingHelperState == nil || awaitingHelperState == value.snapshot.state)
            {
                awaitingHelperState = nil; state = value.snapshot.state
            }
            sources = value.snapshot.sources; sourcesLoaded = true
            cameraAccess =
                value.snapshot.cameraAccess == "authorized"
                ? .authorized
                : value.snapshot.cameraAccess == "notDetermined" ? .notDetermined : .denied
            previewStatistics.sourceWidth = value.snapshot.sourceWidth;
            previewStatistics.sourceHeight = value.snapshot.sourceHeight
            previewStatistics.systemBackgroundActive = value.snapshot.systemBackgroundActive
            previewFailure = value.previewFailure
            previewFeed = .helper; previewRunning = value.preview != nil
            if let reference = value.reference.flatMap(Self.image) {
                helperReference = reference;
                if expandedInspectorSections.contains(.look) {
                    updateLookThumbnails(from: reference)
                }
            }
            if let preview = value.preview.flatMap(Self.image), let buffer = Self.buffer(preview) {
                display.push(buffer)
            }
        } catch is CancellationError {} catch {
            guard !stopped, !Task.isCancelled else { return }
            helperReachable = false; statusPending = false;
            previewFailure = error.localizedDescription
        }
    }

    private static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        }
    }
    private static func buffer(_ image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
                == kCVReturnSuccess, let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, []);
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer),
            let context = CGContext(
                data: pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height));
        return buffer
    }

    func setInspectorExpanded(_ section: VirtualCameraInspectorTab, _ expanded: Bool) {
        if expanded {
            tab = section
        } else {
            expandedInspectorSections.remove(section)
        }
    }

    private enum PreviewFeed {
        case idle
        case pending
        case local
        case helper
    }

    var needsCameraAccess: Bool { state.media.kind == .camera && cameraAccess != .authorized }

    var hasNoCameraSource: Bool {
        state.media.kind == .camera && sourcesLoaded && cameraAccess == .authorized
            && sources.isEmpty && !hasPreviewFrame
            && !(snapshot?.live == true && helperReachable)
            && !(snapshot == nil && statusPending)
            && state.privacy == .live
    }

    var previewLoadingTitle: String? {
        guard state.privacy != .stopped, !hasNoCameraSource, previewFailure == nil,
            !needsCameraAccess || snapshot?.live == true, !hasPreviewFrame
        else { return nil }
        if !sourcesLoaded { return "Finding cameras" }
        if previewFeed == .pending { return "Connecting to Edith Bar" }
        switch state.media.kind {
        case .camera: return "Starting camera"
        case .video: return "Starting video"
        case .screen: return "Starting screen capture"
        }
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
        if state.privacy == .stopped { return "Stopped" }
        if state.media.kind == .video, !meetingPlaying { return "Paused" }
        if let snapshot, helperReachable { return snapshot.headline }
        if statusPending || helperReachable { return "Checking Edith Bar" }
        return "Edith Bar is not answering"
    }

    var isLive: Bool { state.privacy != .stopped && snapshot?.live == true }

    var systemBackgroundActive: Bool {
        guard state.privacy != .stopped else { return false }
        return isLive
            ? snapshot?.systemBackgroundActive == true : previewStatistics.systemBackgroundActive
    }

    func appear() {
        guard !stopped else { return }
        attachments += 1
        guard attachments == 1 else { return }
        visible = true
        statusPending = true
        if engineClient != nil {
            remotePoll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, visible, !stopped else { return }
                    await refreshRemote()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }; return
        }
        setPreviewWanted(true)
        if saveTimer != nil { flushSave() } else { reloadState() }
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
        attachments = max(0, attachments - 1)
        guard visible, attachments == 0 else { return }
        visible = false
        if engineClient != nil {
            remotePoll?.cancel(); remotePoll = nil; statusTask?.cancel(); saveTimer?.invalidate();
            saveTimer = nil; stopPreview(); return
        }
        setPreviewWanted(false)
        flushSave()
        statusTask?.cancel()
        statusTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        sourceTask?.cancel()
        sourceTask = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        if let statusToken { IPC.stopObserving(statusToken) }
        if let stateToken { IPC.stopObserving(stateToken) }
        statusToken = nil
        stateToken = nil
        stopPreview()
    }

    func shutdown() async {
        stopped = true
        remotePoll?.cancel(); await remotePoll?.value; remotePoll = nil
        let requests = Array(localRequests.values); for task in requests { task.cancel() };
        for task in requests { await task.value }; localRequests.removeAll()
        let pending = [statusTask, sourceTask, thumbnailTask, pipelineTask].compactMap { $0 }
        for task in pending { task.cancel() }
        attachments = 1
        if visible { disappear() }
        flushSave()
        for task in pending { await task.value }
        await pipeline?.stopAndDrain()
        previewBus.close()
        display.onAvailabilityChanged = nil
    }

    private func tick() {
        ticks += 1
        if ticks % Self.statusRefreshTicks == 0 || (!helperReachable && !statusPending) {
            requestStatus()
            extensionManager.refreshDetached()
        }
        let statistics = pipeline?.statistics ?? VirtualCameraPipeline.Statistics()
        if statistics.sourceWidth != previewStatistics.sourceWidth
            || statistics.sourceHeight != previewStatistics.sourceHeight
            || statistics.source != previewStatistics.source
            || statistics.systemBackgroundActive != previewStatistics.systemBackgroundActive
            || statistics.failureMessage != previewStatistics.failureMessage
        {
            previewStatistics = statistics
        }
        refreshPreviewHealth()
        if expandedInspectorSections.contains(.look), let reference = previewReference,
            reference !== thumbnailSource
        {
            updateLookThumbnails(from: reference)
        }
        let access = accessProvider()
        if access != cameraAccess {
            cameraAccess = access
            if access == .authorized { syncPreviewFeed() }
        }
    }

    func updateLookThumbnails(from reference: CGImage) {
        guard thumbnailTask == nil else { return }
        thumbnailSource = reference
        thumbnailTask = Task { [weak self] in
            let thumbnails = await Task.detached(priority: .utility) {
                VirtualCameraLooks.thumbnails(from: reference, renderer: Self.thumbnailRenderer)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.lookThumbnails = thumbnails
            self.thumbnailTask = nil
        }
    }

    func waitForLookThumbnails() async {
        await thumbnailTask?.value
    }

    var previewReference: CGImage? {
        previewFeed == .helper ? helperReference : pipeline?.reference
    }

    func refreshPreviewHealth() {
        if previewFeed == .local, let failure = pipeline?.statistics.failureMessage {
            previewFailure = failure
        } else if hasPreviewFrame {
            previewFailure = nil
        } else if !hasPreviewFrame, let started = previewStartedAt, clock() - started >= 8 {
            previewFailure =
                "No video arrived from the camera. Try reconnecting it or choosing another camera."
        }
    }

    func retryPreview() {
        let retriesHelper = previewFeed == .helper
        stopPreview()
        refreshSources()
        requestStatus(retriesHelper ? .retry : .status)
        syncPreviewFeed()
    }

    var canReceiveUIResult: Bool { !stopped && !Task.isCancelled }

    func receive(_ decoded: VirtualCameraSnapshot?) {
        guard !stopped, let decoded else { return }
        statusTask?.cancel()
        statusTask = nil
        statusPending = false
        if snapshot != decoded { snapshot = decoded }
        helperReachable = true
        if saveTimer == nil,
            awaitingHelperState == nil || awaitingHelperState == decoded.state
        {
            awaitingHelperState = nil
            reloadState(decoded.state)
        }
        if visible { syncPreviewFeed() }
    }

    func requestStatus(_ request: VirtualCameraRequest = .status) {
        statusTask?.cancel()
        statusPending = true
        let timeout: Duration = snapshot == nil ? .milliseconds(500) : .seconds(3)
        statusTask = Task { [weak self] in
            do {
                let snapshot = try await self?.performRequest(request, timeout: timeout)
                guard !Task.isCancelled else { return }
                self?.statusPending = false
                self?.receive(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.statusPending = false
                self?.helperReachable = false
                self?.syncPreviewFeed()
            }
        }
    }

    func reloadState(_ announced: VirtualCameraState? = nil) {
        if announced != nil { awaitingHelperState = nil }
        if engineClient != nil && announced == nil { return }
        let stored = announced ?? VirtualCameraStore.load(defaults)
        guard stored != state else { return }
        state = stored
        pipeline?.update(state: stored)
        syncPreviewFeed()
    }

    func refreshSources() {
        if engineClient != nil { return }
        if let sourceProvider {
            sources = sourceProvider()
            sourcesLoaded = true
            return
        }
        sourceTask?.cancel()
        sourceTask = Task { [weak self] in
            let sources = await Task.detached(priority: .userInitiated) {
                VirtualCameraDevices.sources()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.sources = sources
            self.sourcesLoaded = true
            self.syncPreviewFeed()
        }
    }

    func syncPreviewFeed() {
        if engineClient != nil { return }
        guard visible else { return }
        setPreviewWanted(state.privacy != .stopped)
        guard state.privacy != .stopped else {
            stopPreview()
            return
        }
        if snapshot == nil && statusPending && helperReachable {
            previewFeed = .pending
        } else if snapshot?.live == true && helperReachable {
            showHelperPreview()
        } else {
            hideHelperPreview()
            startLocalPreview()
        }
    }

    private func setPreviewWanted(_ wanted: Bool) {
        let bus = previewBus
        previewBusQueue.async { bus.setWanted(wanted) }
    }

    private func showHelperPreview() {
        if previewFeed == .local { pipeline?.stop() }
        if previewFeed != .helper { previewStartedAt = clock() }
        previewFeed = .helper
        previewRunning = true
        guard helperPreviewTimer == nil else { return }
        let bus = previewBus
        let display = display
        let generation = pipelineGeneration
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            if let buffer = bus.latest() { display.push(buffer) }
            if let reference = bus.latestReference() {
                Task { @MainActor [weak self] in
                    guard let self, self.visible, self.previewFeed == .helper,
                        self.pipelineGeneration == generation
                    else { return }
                    self.helperReference = reference
                    if self.expandedInspectorSections.contains(.look) {
                        self.updateLookThumbnails(from: reference)
                    }
                }
            }
        }
        timer.resume()
        helperPreviewTimer = timer
    }

    private func hideHelperPreview() {
        helperPreviewTimer?.cancel()
        helperPreviewTimer = nil
        guard previewFeed == .helper else { return }
        previewFeed = .idle
        helperReference = nil
        previewRunning = false
    }

    private func startLocalPreview() {
        cameraAccess = accessProvider()
        guard visible, (cameraAccess == .authorized || state.media.kind != .camera),
            previewFeed != .local
        else { return }
        guard let pipeline else {
            preparePipeline()
            return
        }
        hideHelperPreview()
        let display = display
        pipeline.update(state: state)
        pipeline.start { buffer in display.push(buffer) }
        previewStartedAt = clock()
        previewFeed = .local
        previewRunning = true
    }

    private func preparePipeline() {
        guard pipelineTask == nil else { return }
        pipelineGeneration += 1
        let generation = pipelineGeneration
        let state = state
        let size = Self.previewSize
        pipelineTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                VirtualCameraPipeline(state: state, outputSize: size)
            }.value
            guard !Task.isCancelled, let self, generation == self.pipelineGeneration,
                self.visible, self.state.privacy != .stopped
            else { return }
            self.pipeline = prepared
            self.pipelineTask = nil
            self.syncPreviewFeed()
        }
    }

    func stopPreview() {
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        hideHelperPreview()
        if previewFeed == .local { pipeline?.stop() }
        previewFeed = .idle
        previewRunning = false
        previewStartedAt = nil
        previewFailure = nil
        helperReference = nil
        display.clear()
    }

    func requestCameraAccess() {
        if let engineClient {
            runAction { _ = try await engineClient.invoke("camera.ui.permission") }; return
        }
        guard cameraAccess == .notDetermined else {
            do {
                guard
                    let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
                    ), NSWorkspace.shared.open(url)
                else { throw CocoaError(.featureUnsupported) }
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
        pipeline?.update(state: next)
        scheduleSave()
        syncPreviewFeed()
    }

    func updateComposition(_ change: (inout VirtualCameraComposition) -> Void) {
        update { change(&$0.composition) }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        saveTimer = timer
    }

    func flushSave() {
        guard saveTimer != nil else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        if let engineClient {
            let intended = state; awaitingHelperState = intended
            runAction { [weak self] in
                let data = try await engineClient.invoke(
                    "camera.ui.state", payload: JSONEncoder().encode(intended))
                guard let self, !stopped, !Task.isCancelled else { return }
                receive(try JSONDecoder().decode(VirtualCameraSnapshot.self, from: data))
            }; return
        }
        guard VirtualCameraStore.load(defaults) != state else { return }
        VirtualCameraStore.save(state, to: defaults)
        if visible { awaitingHelperState = state }
        VirtualCameraStore.announceChange(from: "window", state: state)
    }

    func pan(by translation: CGSize, in viewSize: CGSize) {
        let previous = state
        updateComposition {
            $0.framing = VirtualCameraGeometry.panned(
                $0.framing, by: translation, viewSize: viewSize, source: sourceSize,
                output: outputSize)
        }
        if engineClient == nil, state != previous, snapshot?.live == true {
            VirtualCameraStore.announceChange(from: "window", state: state)
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
        update {
            $0.sourceID = source.id
            $0.media = VirtualCameraMedia()
            $0.privacy = .live
        }
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
        guard mode != .stopped || snapshot?.recordingPath == nil else {
            errorMessage = "Stop the recording before stopping the camera."
            return
        }
        update { $0.privacy = mode }
        flushSave()
    }

    func resume() {
        update { $0.privacy = .live }
        flushSave()
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
        if let engineClient {
            runAction { [weak self] in
                let input = CameraUIAsset(
                    path: url.path, target: target == .logo ? "logo" : "background")
                let data = try await engineClient.invoke(
                    "camera.ui.importAsset", payload: JSONEncoder().encode(input))
                guard let self, !stopped, !Task.isCancelled else { return }
                receive(try JSONDecoder().decode(VirtualCameraSnapshot.self, from: data))
            }; return
        }
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
            if engineClient == nil { VirtualCameraStore.pruneAssets(keeping: state) }
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
        if engineClient == nil { VirtualCameraStore.pruneAssets(keeping: state) }
    }

    func showPreviewFrame(_ buffer: CVPixelBuffer) {
        display.push(buffer)
        display.flush()
    }

    func renderPreview(from pixelBuffer: CVPixelBuffer, at time: TimeInterval = 1) {
        guard let pipeline else { return }
        pipeline.update(state: state)
        guard let rendered = pipeline.process(pixelBuffer, at: time) else { return }
        showPreviewFrame(rendered)
    }

    func injectForTesting(snapshot: VirtualCameraSnapshot?, sources: [VirtualCameraSource]) {
        self.snapshot = snapshot
        self.sources = sources
        sourcesLoaded = true
        helperReachable = snapshot != nil
    }
}
