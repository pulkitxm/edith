import AVFoundation
import AppKit
import EdithExtensionSupport
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class VideoEditorModel {
    private struct LoadedProject: @unchecked Sendable {
        var document: VideoProject
        let missingAssetIDs: Set<String>
    }
    private struct SessionMedia: Sendable {
        let cameraPath: String?
        let cameraOffset: Int
        let microphonePath: String?
        let microphoneOffset: Int
    }
    let facade: StudioUIFacade?
    var remoteMetadata: VideoPreviewMetadata?
    var remoteFrame: CGImage?
    var remoteFocusFrame: CGImage?
    var remoteFocusReady = false
    var remotePlaybackRate: Float = 0
    private var remoteClient: StudioUIVideoClient?
    private var transcriptionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private let remoteExporter = VideoExporter()
    var exporter: VideoExporter { facade == nil ? VideoExporter.shared : remoteExporter }
    var previewMetadata: VideoPreviewMetadata? {
        remoteMetadata ?? pipeline.map(VideoPreviewMetadata.init)
    }
    var remoteSessionID: UUID? { remoteClient?.id }
    var playbackRate: Float { facade == nil ? player.rate : remotePlaybackRate }
    var focusReady: Bool { facade == nil ? focusPreviewReady : remoteFocusReady }

    var project: VideoProject? {
        didSet {
            reconcileCaptionDrafts()
            if !isClosed { liveSync?.watch(project?.fileURL) }
        }
    }
    var externalSyncMessage: String?
    private var liveSync: VideoEditorLiveSync?
    private var isClosed = false
    var captionDrafts: [String: VideoCaptionDraft] = [:]
    var selectedClipID: String?
    var selection: VideoSelection?
    var canvasEditing = true
    var safeAreas = false
    var audioTask: Task<Void, Never>?
    var audioStatus: String?
    var silentRanges: [ClosedRange<Double>] = []
    var silenceClipID: String?
    var playhead = 0.0
    var zoomDepth = 4
    var regionSpeed = 2.0
    var zoomDuration = 2.0
    var focusX = 0.5
    var focusY = 0.5
    var editingZoomID: String?
    var captionText = ""
    var captionDuration = 3.0
    var isTranscribing = false
    var gifFPS = 15
    var gifWidth = 0
    var gifLoop = true
    var loopPlayback = false {
        didSet { remoteClient?.send("studio.ui.video.loop", object: ["enabled": loopPlayback]) }
    }
    var errorMessage: String?
    var permissionSettingsURL: URL?
    var recentProjects: [VideoProject.Listing] = []
    private(set) var hasUnsavedEdits = false
    var titleDraft: String?
    private(set) var pendingViewEditIDs: Set<String> = []
    private var pendingLoads = 0
    private(set) var isRebuildingPreview = false
    var isPreparingPreview: Bool { pendingLoads > 0 || isRebuildingPreview }
    var blocksCommandOpen: Bool {
        hasUnsavedEdits || isTranscribing || audioStatus != nil || pendingLoads > 0
            || titleDraft.map { $0 != (project?.title ?? "") } == true
            || !pendingViewEditIDs.isEmpty
    }

    func setPendingViewEdit(_ id: String, hasChanges: Bool) {
        if hasChanges {
            pendingViewEditIDs.insert(id)
        } else {
            pendingViewEditIDs.remove(id)
        }
    }

    private func replaceProject(_ next: VideoProject) {
        if project?.id != next.id {
            titleDraft = nil
            pendingViewEditIDs.removeAll()
            captionDrafts.removeAll()
        }
        project = next
    }

    private(set) var player = AVPlayer()
    let focusPlayer = AVPlayer()
    private(set) var focusPreviewReady = false
    private(set) var pipeline: VideoRenderPipeline?
    private var observer: Any?
    private var generation = 0
    private var focusPreviewGeneration = 0
    private var rebuildTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var relinkPanel: NSOpenPanel?
    private var focusPreviewTask: Task<Void, Never>?
    private let previewBuilder: (VideoProject) async throws -> VideoRenderPipeline
    private var playerSeeker: VideoPreviewSeeker?
    private var focusSeeker: VideoPreviewSeeker?
    private var undoHistory: [VideoProject] = []
    private var redoHistory: [VideoProject] = []
    static let maximumUndoSteps = 128

    var duration: Double { previewMetadata?.duration ?? 0 }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var maximumZoomDuration: Double {
        guard let editingZoomID, let project,
            let zoom = project.zooms.first(where: { $0.id == editingZoomID }),
            let clip = project.clips.first(where: { $0.id == zoom.raw["clipId"] as? String })
        else { return 6 }
        var next = Double.greatestFiniteMagnitude
        for candidate in project.zooms where candidate.id != editingZoomID {
            if candidate.startMs > zoom.startMs {
                next = min(next, candidate.startMs)
            }
        }
        let upper = min((clip.timelineStart + clip.duration) * 1000, next)
        return max(0.1, (upper - zoom.startMs) / 1000)
    }

    init(
        previewBuilder: @escaping (VideoProject) async throws -> VideoRenderPipeline = {
            try await VideoRenderPipeline.make(project: $0, previewOnly: true)
        }, facade: StudioUIFacade? = nil
    ) {
        self.facade = facade
        self.previewBuilder = previewBuilder
        playerSeeker = VideoPreviewSeeker(player: player)
        focusSeeker = VideoPreviewSeeker(player: focusPlayer)
        if let facade {
            remoteClient = StudioUIVideoClient(model: self, facade: facade)
        } else {
            liveSync = VideoEditorLiveSync(model: self)
            refreshRecentProjects()
            observePlaybackTime()
        }
    }

    private func observePlaybackTime() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite, self.playerSeeker?.isSeeking != true else {
                    return
                }
                self.playhead = time.seconds
                if self.loopPlayback, self.duration > 0,
                    time.seconds >= self.duration
                        - (self.previewMetadata?.frameDuration.seconds ?? 0.03)
                {
                    self.seek(to: 0); self.player.play()
                }
            }
        }
    }

    func close() {
        remoteClient?.close()
        transcriptionTask?.cancel()
        importTask?.cancel()
        isClosed = true
        isRebuildingPreview = false
        generation += 1
        focusPreviewGeneration += 1
        rebuildTask?.cancel()
        openTask?.cancel()
        relinkPanel?.cancel(nil)
        focusPreviewTask?.cancel()
        resetPreviewSeeks()
        liveSync?.stop()
        audioTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        focusPlayer.pause()
        focusPlayer.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func newProject() {
        if let remoteClient { remoteClient.create(); return }
        openTask?.cancel()
        relinkPanel?.cancel(nil)
        isClosed = false
        audioTask?.cancel()
        selection = nil
        silentRanges = []
        player.pause()
        replaceProject(.create())
        selectedClipID = nil
        editingZoomID = nil
        undoHistory.removeAll()
        redoHistory.removeAll()
        saveInLibrary()
        rebuild()
    }

    func startProject(with urls: [URL]) {
        if let remoteClient { remoteClient.startProject(urls); return }
        newProject()
        importTask?.cancel()
        importTask = Task { await addMedia(urls) }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "openscreen")!]
        panel.directoryURL = VideoProject.libraryURL
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.openProject(at: url)
            }
        }
    }

    func openProject(at url: URL) {
        if let remoteClient { remoteClient.open(url); return }
        openTask?.cancel()
        relinkPanel?.cancel(nil)
        rebuildTask?.cancel()
        isRebuildingPreview = false
        generation += 1
        let version = generation
        pendingLoads += 1
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { pendingLoads -= 1 }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    var document = try VideoProject.open(url)
                    document.relinkMediaNextToProject()
                    let missingAssetIDs = Set(
                        document.assets.filter {
                            !FileManager.default.fileExists(atPath: $0.url.path)
                        }.map(\.id))
                    let registered = try VideoProjectRegistry().records().contains {
                        $0.projectID == document.id
                            && VideoProjectFileAccess.identity(URL(fileURLWithPath: $0.path))
                                == VideoProjectFileAccess.identity(url)
                    }
                    if !registered, url.path.hasPrefix(VideoProject.openScreenLibraryURL.path + "/")
                    {
                        document.fileURL = nil
                    }
                    return LoadedProject(document: document, missingAssetIDs: missingAssetIDs)
                }.value
                guard !Task.isCancelled, version == generation else { return }
                var document = loaded.document
                for asset in document.assets
                where loaded.missingAssetIDs.contains(asset.id) {
                    let panel = NSOpenPanel()
                    panel.message = "Locate \(asset.label) to open this project"
                    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                    relinkPanel = panel
                    let replacement: URL? = await withCheckedContinuation { continuation in
                        panel.begin { response in
                            MainActor.assumeIsolated {
                                continuation.resume(returning: response == .OK ? panel.url : nil)
                            }
                        }
                    }
                    if relinkPanel === panel { relinkPanel = nil }
                    guard !Task.isCancelled, version == generation else { return }
                    if let replacement {
                        document.relinkMedia(assetID: asset.id, to: replacement)
                    }
                }
                isClosed = false
                replaceProject(document)
                hasUnsavedEdits = false
                selectedClipID = project?.clips.first?.id
                editingZoomID = nil
                undoHistory.removeAll()
                redoHistory.removeAll()
                rebuildTask?.cancel()
                player.pause()
                resetPreviewSeeks()
                player.replaceCurrentItem(with: nil)
                pipeline = nil
                let prepared = await document.probingMissingMedia()
                guard !Task.isCancelled, version == generation, project?.id == prepared.id else {
                    return
                }
                project = prepared
                if prepared.fileURL == nil { saveInLibrary() }
                rebuild()
            } catch {
                guard !Task.isCancelled, version == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshRecentProjects() {
        if facade != nil {
            recentProjects = facade?.state?.projects.map(\.value) ?? recentProjects; return
        }
        recentProjects = VideoProject.listProjects()
    }

    func acceptExternalProject(
        _ next: VideoProject, prepared: VideoRenderPipeline?, playbackPlayer: AVPlayer?
    ) {
        let time = playhead
        isRebuildingPreview = false
        let rate = player.rate
        generation += 1
        rebuildTask?.cancel()
        titleDraft = nil
        replaceProject(next)
        hasUnsavedEdits = false
        if !next.clips.contains(where: { $0.id == selectedClipID }) {
            selectedClipID = next.clips.first?.id
        }
        selection = nil
        if !next.zooms.contains(where: { $0.id == editingZoomID }) {
            editingZoomID = nil
        }
        undoHistory.removeAll()
        redoHistory.removeAll()
        pipeline = prepared
        resetPreviewSeeks()
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        player.replaceCurrentItem(with: nil)
        player = playbackPlayer ?? AVPlayer()
        playerSeeker = VideoPreviewSeeker(player: player)
        observePlaybackTime()
        seek(to: min(time, prepared?.duration ?? 0))
        if rate != 0, player.currentItem != nil { player.rate = rate }
        updateFocusPreview()
        externalSyncMessage = nil
        refreshRecentProjects()
    }

    func discardLocalEditsAndRefresh() {
        if let remoteClient { remoteClient.refresh(discard: true); return }
        guard !isTranscribing, audioStatus == nil, pendingLoads == 0 else { return }
        titleDraft = nil
        pendingViewEditIDs.removeAll()
        captionDrafts.removeAll()
        hasUnsavedEdits = false
        liveSync?.refresh()
    }

    func loadCommandProject(_ request: VideoEditorService.OpenRequest) async throws {
        isClosed = false
        generation += 1
        rebuildTask?.cancel()
        focusPreviewTask?.cancel()
        resetPreviewSeeks()
        let version = generation
        let url = URL(fileURLWithPath: request.path)
        let snapshot = try VideoEditorService.readProject(url)
        let fingerprint = snapshot.revision.fingerprint.digest.map { String(format: "%02x", $0) }
            .joined()
        guard snapshot.project.id == request.projectID, fingerprint == request.revision else {
            throw VideoEditorService.Failure(
                "project_changed", "The requested project revision changed before loading.")
        }
        guard snapshot.project.fileURL != nil else {
            throw VideoEditorService.Failure(
                "migration_required",
                "Convert this legacy project to the current format before opening it from the command line."
            )
        }
        for url in VideoEditorService.sourceURLs(snapshot.project, includeSidecars: false) {
            do { try VideoEditorService.requireLocalFile(url) } catch {
                throw VideoEditorService.Failure(
                    "missing_media", "Required media is unavailable: \(url.path)")
            }
        }
        try await VideoEditorService.validateMedia(snapshot.project)
        let prepared: VideoRenderPipeline?
        if snapshot.project.clips.isEmpty {
            prepared = nil
        } else {
            prepared = try await VideoRenderPipeline.make(
                project: snapshot.project, previewOnly: true)
        }
        try Task.checkCancellation()
        guard !isClosed, version == generation else { throw CancellationError() }
        replaceProject(snapshot.project)
        hasUnsavedEdits = false
        selectedClipID = snapshot.project.clips.first?.id
        pipeline = prepared
        if let prepared {
            let item = AVPlayerItem(asset: prepared.composition)
            item.videoComposition = prepared.videoComposition
            item.audioMix = prepared.audioMix
            player.replaceCurrentItem(with: item)
            while item.status != .readyToPlay {
                try Task.checkCancellation()
                guard !isClosed, version == generation else { throw CancellationError() }
                if item.status == .failed {
                    throw VideoEditorService.Failure(
                        "open_failed",
                        item.error?.localizedDescription
                            ?? "The native player could not load this project.")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
        }
        guard !isClosed, version == generation else { throw CancellationError() }
        try verifyCommandProject(request)
    }

    func verifyCommandProject(_ request: VideoEditorService.OpenRequest) throws {
        guard let project, project.id == request.projectID,
            project.fileURL?.path == request.path,
            project.clips.isEmpty
                || (pipeline != nil && player.currentItem?.status == .readyToPlay),
            let revision = project.fileRevision?.value,
            revision.digest.map({ String(format: "%02x", $0) }).joined() == request.revision,
            try revision.matches(URL(fileURLWithPath: request.path))
        else {
            throw VideoEditorService.Failure(
                "project_changed", "The requested project revision is no longer current.")
        }
    }

    func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose videos, images, or audio for your edit."
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK else { return }
                let urls = panel.urls
                self.importTask?.cancel()
                self.importTask = Task { await self.addMedia(urls) }
            }
        }
    }

    func addMedia(_ urls: [URL]) async {
        if let remoteClient { await remoteClient.importMedia(urls); return }
        pendingLoads += 1
        defer { pendingLoads -= 1 }
        do {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true {
                    let metadata = try await Task.detached(priority: .utility) {
                        try VideoStillMedia.metadata(at: url)
                    }.value
                    if project == nil {
                        project = .create(title: url.deletingPathExtension().lastPathComponent)
                    }
                    mutate { try? $0.addStillAsset(url, metadata: metadata) }
                } else if type?.conforms(to: .movie) == true
                    || type?.conforms(to: .audio) != true
                {
                    try await addFile(url)
                }
            }
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .audio) == true,
                    type?.conforms(to: .movie) != true
                {
                    try await addAudioFile(url)
                }
            }
            selectedClipID = project?.clips.last?.id
            if project?.fileURL == nil { saveInLibrary() }
            rebuild()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addAudioFile(_ url: URL) async throws {
        guard let project, !project.clips.isEmpty else {
            throw VideoRenderPipeline.RenderError.exportFailed(
                "Add a video or image before adding audio to the timeline.")
        }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw VideoRenderPipeline.RenderError.exportFailed(
                "This audio file has no playable duration.")
        }
        guard !Task.isCancelled, self.project?.id == project.id else { return }
        mutate { $0.addAudio(url, duration: duration, at: playhead * 1000) }
    }

    func removeAudio(_ id: String) {
        mutate { $0.removeAudioTrack(id) }
        rebuild()
    }

    func setAudioGain(_ id: String, decibels: Double) {
        mutate { $0.setAudioGain(id, decibels: decibels) }
        rebuild()
    }

    func setAudioMuted(_ id: String, muted: Bool) {
        mutate { $0.setAudioOptions(id, muted: muted) }
        rebuild()
    }

    func setAudioLoop(_ id: String, loop: Bool) {
        mutate { $0.setAudioOptions(id, loop: loop) }
        rebuild()
    }

    func setAudioFade(_ id: String, milliseconds: Int, fadeIn: Bool) {
        mutate {
            if fadeIn {
                $0.setAudioOptions(id, fadeInMs: milliseconds)
            } else {
                $0.setAudioOptions(id, fadeOutMs: milliseconds)
            }
        }
        rebuild()
    }

    private func addFile(
        _ url: URL, label: String? = nil
    ) async throws {
        if project == nil {
            project = .create(
                title: url.deletingPathExtension().lastPathComponent)
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
            let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw VideoRenderPipeline.RenderError.noVideo }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = CGRect(origin: .zero, size: size).applying(transform).size
        let fps = try await track.load(.nominalFrameRate)
        let minimumFrameDuration = try await track.load(.minFrameDuration)
        let formats = try await track.load(.formatDescriptions)
        let sourceMetadata = VideoSourceMetadata.make(
            width: Int(abs(displayedSize.width)), height: Int(abs(displayedSize.height)),
            fps: Double(fps), frameDuration: minimumFrameDuration, format: formats.first)
        let manifestURL = URL(fileURLWithPath: url.path + ".session.json")
        let session = await Task.detached(priority: .utility) { () -> SessionMedia? in
            guard let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return SessionMedia(
                cameraPath: manifest["webcamVideoPath"] as? String,
                cameraOffset: (manifest["webcamOffsetMs"] as? NSNumber)?.intValue ?? 0,
                microphonePath: manifest["microphoneAudioPath"] as? String,
                microphoneOffset: (manifest["microphoneOffsetMs"] as? NSNumber)?.intValue ?? 0)
        }.value
        let microphoneURL = session?.microphonePath.map { URL(fileURLWithPath: $0) }
        let microphoneDuration: Double?
        if let microphoneURL {
            microphoneDuration = try? await AVURLAsset(url: microphoneURL).load(.duration).seconds
        } else {
            microphoneDuration = nil
        }
        mutate {
            $0.addAsset(
                url, duration: duration,
                width: Int(abs(displayedSize.width)), height: Int(abs(displayedSize.height)),
                label: label, sourceMetadata: sourceMetadata)
            if let session, let cameraPath = session.cameraPath,
                let assetID = $0.assets.last?.id
            {
                $0.attachCamera(
                    URL(fileURLWithPath: cameraPath), to: assetID,
                    offsetMs: session.cameraOffset)
            }
            if let microphoneURL, let microphoneDuration,
                microphoneDuration.isFinite, microphoneDuration > 0,
                let clipID = $0.clips.last?.id,
                let clipStart = VideoRenderPipeline.timingSegments(project: $0)
                    .first(where: { $0.clip.id == clipID })?.outputStart
            {
                let offset = session?.microphoneOffset ?? 0
                $0.addAudio(
                    microphoneURL, duration: microphoneDuration,
                    at: clipStart * 1000 + Double(max(0, offset)),
                    sourceOffsetMs: Double(max(0, -offset)))
            }
        }
    }

    func save() {
        guard let project else { return }
        if let existing = project.fileURL {
            saveProject(to: existing)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "openscreen")!]
        panel.nameFieldStringValue = "\(project.title).openscreen"
        panel.directoryURL = VideoProject.libraryURL
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.saveProject(to: url)
            }
        }
    }

    private func saveProject(to url: URL) {
        if let remoteClient, let project { remoteClient.save(project, to: url); return }
        guard var project else { return }
        hasUnsavedEdits = true
        do {
            try project.save(to: url)
            self.project = project
            hasUnsavedEdits = false
            refreshRecentProjects()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveInLibrary() {
        if let remoteClient, let project { remoteClient.persist(project); return }
        guard var project else { return }
        hasUnsavedEdits = true
        do {
            try FileManager.default.createDirectory(
                at: VideoProject.libraryURL, withIntermediateDirectories: true)
            let url = VideoProject.libraryURL.appendingPathComponent("\(project.id).openscreen")
            try project.save(to: url)
            self.project = project
            hasUnsavedEdits = false
            refreshRecentProjects()
        } catch { errorMessage = error.localizedDescription }
    }

    func export(
        gif: Bool, quality: VideoExportQuality = .source,
        delivery: VideoDeliverySettings = .init()
    ) {
        guard previewMetadata != nil, let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            gif ? .gif : delivery.codec.isMaster ? .quickTimeMovie : .mpeg4Movie
        ]
        panel.nameFieldStringValue =
            "\(project.title).\(gif ? "gif" : delivery.codec.fileExtension)"
        let fps = gifFPS
        let width = gifWidth
        let loop = gifLoop
        let chosen: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard !project.protectsMedia(at: url) else {
                self.errorMessage =
                    "Choose an export destination different from your project and source media."
                return
            }
            if let remoteClient = self.remoteClient {
                let exporter = self.exporter
                exporter.start(to: url) { progress in
                    let report = try await remoteClient.export(
                        to: url, gif: gif, quality: quality, settings: delivery,
                        fps: fps, width: width, loop: loop
                    ) { value in progress(value) }
                    if let report { exporter.setReport(report, for: url) }
                }
                return
            }
            VideoExporter.shared.start(to: url) { progress in
                if gif {
                    let render = try await VideoRenderPipeline.make(project: project)
                    try await render.exportGIF(
                        to: url, fps: fps, maxWidth: width, loop: loop, progress: progress)
                    return
                }
                let render = try await VideoRenderPipeline.make(
                    project: project, maxDimension: quality.maxDimension)
                let report = try await render.export(
                    to: url, settings: delivery, overwrite: true, progress: progress)
                await MainActor.run { VideoExporter.shared.setReport(report, for: url) }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    func togglePlayback() {
        if let remoteClient { remoteClient.send("studio.ui.video.play"); return }
        if player.rate == 0 {
            if playhead >= duration - 0.1 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
            if focusPreviewReady {
                focusSeeker?.request(CMTime(seconds: playhead, preferredTimescale: 60000))
            }
        }
    }

    func seek(to seconds: Double) {
        if let remoteClient {
            playhead = min(max(0, seconds), duration);
            remoteClient.send("studio.ui.video.seek", object: ["time": playhead]); return
        }
        guard seconds.isFinite else { return }
        let clamped = max(0, min(duration, seconds))
        playhead = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 60000)
        if player.currentItem != nil { playerSeeker?.request(time) }
        if focusPreviewReady {
            focusSeeker?.request(time)
        }
    }

    private func resetPreviewSeeks() {
        playerSeeker?.reset()
        player.currentItem?.cancelPendingSeeks()
        focusSeeker?.reset()
        focusPlayer.currentItem?.cancelPendingSeeks()
    }

    func splitAtPlayhead() {
        if case .audio(let id) = selection {
            splitAudio(id, at: playhead)
            return
        }
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let sourceTime = segment.sourceTime(at: playhead)
        mutate { $0.split(clipID: segment.clip.id, at: sourceTime) }
        rebuild()
    }

    func skipAtPlayhead() {
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let sourceTime = segment.sourceTime(at: playhead)
        mutate {
            $0.addTrim(
                clipID: segment.clip.id, start: sourceTime,
                end: min(segment.clip.end, sourceTime + 1))
        }
        rebuild()
    }

    func removeTrim(_ id: String) {
        mutate { $0.removeTrim(id) }
        rebuild()
    }

    func trimSelected(start: Double, end: Double) {
        guard let id = selectedClipID else { return }
        mutate { $0.trim(clipID: id, start: start, end: end) }
        rebuild()
    }

    func setRate(_ rate: Double) {
        guard let id = selectedClipID else { return }
        mutate { document in
            var clips = document.clips
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
            clips[index].rate = max(0.25, min(4, rate))
            document.setClips(clips)
        }
        rebuild()
    }

    func setCrop(x: Double, y: Double, width: Double, height: Double) {
        guard let id = selectedClipID else { return }
        mutate { $0.crop(clipID: id, x: x, y: y, width: width, height: height) }
        rebuild()
    }

    func resetCrop() {
        guard let id = selectedClipID else { return }
        mutate { $0.resetCrop(clipID: id) }
        rebuild()
    }

    func removeSelected() {
        guard let id = selectedClipID else { return }
        mutate { document in document.setClips(document.clips.filter { $0.id != id }) }
        selectedClipID = project?.clips.first?.id
        editingZoomID = nil
        rebuild()
    }

    func duplicateSelected() {
        guard let id = selectedClipID else { return }
        var duplicateID: String?
        mutate { duplicateID = $0.duplicate(clipID: id) }
        selectedClipID = duplicateID
        rebuild()
    }

    func renameProject(_ title: String) {
        mutate { $0.rename(title) }
        refreshRecentProjects()
    }

    func moveSelected(by offset: Int) {
        guard let id = selectedClipID else { return }
        mutate { document in
            var clips = document.clips
            guard let index = clips.firstIndex(where: { $0.id == id }),
                clips.indices.contains(index + offset)
            else { return }
            clips.swapAt(index, index + offset)
            document.setClips(clips)
        }
        rebuild()
    }

    func addZoom() {
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let start = segment.rulerTime(at: playhead) * 1000
        let end = min(
            (segment.clip.timelineStart + segment.clip.duration) * 1000,
            start + zoomDuration * 1000)
        mutate {
            $0.addZoom(
                startMs: start, endMs: end,
                depth: zoomDepth, x: focusX, y: focusY)
        }
        editingZoomID = project?.zooms.last?.id
        rebuild()
    }

    func selectZoom(_ zoom: VideoProject.Zoom) {
        editingZoomID = zoom.id
        zoomDepth = zoom.depth
        zoomDuration = (zoom.endMs - zoom.startMs) / 1000
        focusX = zoom.focusX
        focusY = zoom.focusY
        let midpoint = (zoom.startMs + zoom.endMs) / 2000
        if let segment = previewMetadata?.segments.first(where: {
            let ruler = midpoint
            let start = $0.clip.timelineStart + $0.sourceStart - $0.clip.start
            let end = $0.clip.timelineStart + $0.sourceEnd - $0.clip.start
            return ruler >= start && ruler < end
        }) {
            let source = segment.clip.start + midpoint - segment.clip.timelineStart
            seek(to: segment.outputStart + (source - segment.sourceStart) / segment.rate)
        }
        updateFocusPreview()
    }

    func outputTime(forRulerTime ruler: Double) -> Double {
        guard let pipeline = previewMetadata else { return 0 }
        if let segment = pipeline.segments.first(where: {
            let start = $0.clip.timelineStart + $0.sourceStart - $0.clip.start
            let end = $0.clip.timelineStart + $0.sourceEnd - $0.clip.start
            return ruler >= start && ruler < end
        }) {
            let source = segment.clip.start + ruler - segment.clip.timelineStart
            return segment.outputStart + (source - segment.sourceStart) / segment.rate
        }
        return pipeline.segments.first(where: {
            $0.clip.timelineStart + $0.sourceStart - $0.clip.start >= ruler
        })?.outputStart ?? pipeline.duration
    }

    func setZoomTiming(_ id: String, start: Double, end: Double) {
        guard let zoom = project?.zooms.first(where: { $0.id == id }),
            let clipID = zoom.raw["clipId"] as? String
                ?? project?.clips.first(where: {
                    zoom.startMs >= $0.timelineStart * 1000
                        && zoom.startMs < ($0.timelineStart + $0.duration) * 1000
                })?.id,
            let segments = previewMetadata?.segments.filter({ $0.clip.id == clipID }),
            let first = segments.first, let last = segments.last,
            start.isFinite, end.isFinite, end - start >= 0.1
        else { return }
        let bounds = first.outputStart...last.outputEnd
        func ruler(at output: Double) -> Double {
            let segment = segments.first(where: { output < $0.outputEnd }) ?? last
            return segment.rulerTime(at: output) * 1000
        }
        let nextStart = ruler(at: max(bounds.lowerBound, min(bounds.upperBound, start)))
        let nextEnd = ruler(at: max(bounds.lowerBound, min(bounds.upperBound, end)))
        let wasSelected = editingZoomID == id
        mutate { $0.updateZoomTiming(id, startMs: nextStart, endMs: nextEnd) }
        editingZoomID = id
        if let zoom = project?.zooms.first(where: { $0.id == id }) {
            zoomDepth = zoom.depth
            zoomDuration = (zoom.endMs - zoom.startMs) / 1000
            focusX = zoom.focusX
            focusY = zoom.focusY
        }
        if !wasSelected { updateFocusPreview() }
        rebuild(refreshFocusPreview: false)
    }

    func setZoomDepth(_ depth: Int) {
        zoomDepth = depth
        let magnification = [1.25, 1.5, 1.8, 2.2, 3.5, 5.0][max(0, min(5, depth - 1))]
        let margin = 0.5 / magnification
        focusX = min(1 - margin, max(margin, focusX))
        focusY = min(1 - margin, max(margin, focusY))
        guard let editingZoomID else { return }
        let automatic =
            project?.zooms.first(where: { $0.id == editingZoomID })?
            .raw["focusMode"] as? String == "auto"
        mutate {
            $0.updateZoom(
                editingZoomID, depth: depth,
                x: automatic ? nil : focusX, y: automatic ? nil : focusY)
        }
        rebuild(refreshFocusPreview: false)
    }

    func setZoomDuration(_ duration: Double) {
        zoomDuration = min(maximumZoomDuration, duration)
        guard let editingZoomID else { return }
        mutate { $0.updateZoom(editingZoomID, duration: zoomDuration) }
        rebuild(refreshFocusPreview: false)
    }

    func setZoomFocus(x: Double, y: Double) {
        focusX = x
        focusY = y
        guard let editingZoomID else { return }
        mutate { $0.updateZoom(editingZoomID, x: x, y: y) }
        rebuild(refreshFocusPreview: false)
    }

    func addSpeedAtPlayhead() {
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let start = segment.rulerTime(at: playhead) * 1000
        let end = min(
            (segment.clip.timelineStart + segment.clip.duration) * 1000,
            start + 2000)
        mutate { $0.addSpeed(startMs: start, endMs: end, rate: regionSpeed) }
        rebuild()
    }

    func removeSpeed(_ id: String) {
        mutate { $0.removeSpeed(id) }
        rebuild()
    }

    func addAutomaticZooms() {
        guard var document = project else { return }
        let added = document.addAutomaticZooms()
        if added == 0 {
            errorMessage =
                "No click telemetry was found next to the imported videos. OpenScreen recordings store it in a .cursor.json sidecar."
        } else {
            mutate { $0 = document }
            rebuild()
        }
    }

    func removeZoom(_ id: String) {
        mutate { document in
            var remaining: [[String: Any]] = []
            for zoom in document.zooms where zoom.id != id { remaining.append(zoom.raw) }
            document.root["zoomRanges"] = remaining
        }
        if editingZoomID == id { editingZoomID = nil }
        rebuild()
    }

    func setTransition(before clipID: String, kind: String, duration: Double) {
        mutate { $0.setTransition(before: clipID, kind: kind, duration: duration) }
        rebuild()
    }

    func addCaption() {
        let text = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let start = segment.rulerTime(at: playhead) * 1000
        let end = min(
            (segment.clip.timelineStart + segment.clip.duration) * 1000,
            start + captionDuration * 1000)
        mutate { $0.addText(text, startMs: start, endMs: end) }
        captionText = ""
        rebuild()
    }

    func generateCaptions() {
        if remoteAction("captions") { return }
        guard let clip = project?.clips.first(where: { $0.id == selectedClipID }),
            let asset = project?.assets.first(where: { $0.id == clip.assetID })
        else { return }
        isTranscribing = true
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            do {
                let words = try await VideoTranscription.transcribe(asset.url)
                mutate { $0.addTranscription(assetID: asset.id, words: words) }
                rebuild()
            } catch {
                if case VideoTranscription.Error.permission = error {
                    permissionSettingsURL = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                    )
                }
                errorMessage = error.localizedDescription
            }
            isTranscribing = false
        }
    }

    func seekToWord(_ word: VideoProject.TranscriptWord) {
        guard
            let segment = previewMetadata?.segments.first(where: {
                $0.clip.assetID == word.assetID
                    && word.start >= $0.sourceStart && word.start < $0.sourceEnd
            })
        else { return }
        seek(to: segment.outputStart + (word.start - segment.sourceStart) / segment.rate)
    }

    func editTranscriptWord(_ id: String, text: String) {
        mutate { $0.editTranscriptWord(id, text: text) }
        rebuild()
    }

    func removeCaption(_ id: String) {
        mutate { document in
            let annotations = document.root["annotations"] as? [[String: Any]] ?? []
            document.root["annotations"] = annotations.filter { $0["id"] as? String != id }
        }
        rebuild()
    }

    func updateCaption(_ id: String, text: String) {
        if let style = project?.annotations.first(where: { $0.id == id })?.captionStyle {
            do { _ = try VideoStyledCaptionImage.layout(text, style: style) } catch {
                errorMessage = error.localizedDescription; return
            }
        }
        mutate { document in
            var annotations = document.root["annotations"] as? [[String: Any]] ?? []
            guard let index = annotations.firstIndex(where: { $0["id"] as? String == id })
            else { return }
            annotations[index]["content"] = text
            annotations[index]["textContent"] = text
            document.root["annotations"] = annotations
        }
        rebuild()
    }

    func setAnnotationStyle(_ id: String, key: String, value: Any) {
        mutate { $0.setAnnotationStyle(id, key: key, value: value) }
        rebuild()
    }

    func setAnnotationPosition(_ id: String, axis: String, value: Double) {
        mutate { $0.setAnnotationPosition(id, axis: axis, value: value) }
        rebuild()
    }

    func setAnnotationSize(_ id: String, axis: String, value: Double) {
        guard ["width", "height"].contains(axis), value.isFinite else { return }
        mutate {
            var regions = $0.root["annotations"] as? [[String: Any]] ?? []
            guard let index = regions.firstIndex(where: { $0["id"] as? String == id }) else {
                return
            }
            var size = regions[index]["size"] as? [String: Double] ?? [:]
            size[axis] = min(100, max(1, value))
            regions[index]["size"] = size
            $0.root["annotations"] = regions
        }
        rebuild()
    }

    func addOverlay(_ type: String) {
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let start = segment.rulerTime(at: playhead) * 1000
        if type == "image" {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .heic]
            guard panel.runModal() == .OK, let url = panel.url
            else { return }
            Task {
                let data: Data?
                if let facade {
                    data = try? await facade.readFile(url)
                } else {
                    data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }
                        .value
                }
                guard let data else { return }
                let mime =
                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                mutate {
                    $0.addOverlay(
                        type: type, startMs: start,
                        endMs: min(
                            start + 2500,
                            (segment.clip.timelineStart + segment.clip.duration) * 1000),
                        x: focusX, y: focusY,
                        content: "data:\(mime);base64,\(data.base64EncodedString())")
                }
                rebuild()
            }
            return
        }
        mutate {
            $0.addOverlay(
                type: type, startMs: start,
                endMs: min(
                    start + 2500, (segment.clip.timelineStart + segment.clip.duration) * 1000),
                x: focusX, y: focusY)
        }
        rebuild()
    }

    func setBackground(_ color: String) {
        mutate { $0.backgroundColor = color }
        rebuild()
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBackground(url.path)
        setPresentation(\.gradient, false)
    }

    func setAspectRatio(_ ratio: String) {
        mutate { try? $0.setCanvasAspectRatio(ratio) }
        rebuild()
    }

    func setPadding(_ value: Double) {
        mutate { $0.padding = value }
        rebuild()
    }

    func setPresentation<Value>(
        _ keyPath: WritableKeyPath<VideoPresentation, Value>, _ value: Value
    ) {
        mutate {
            var settings = $0.presentation
            settings[keyPath: keyPath] = value
            $0.presentation = settings
        }
        rebuild(refreshFocusPreview: false)
    }

    func removeCameraFromSelectedClip() {
        guard let clip = project?.clips.first(where: { $0.id == selectedClipID }) else { return }
        mutate {
            var assets = $0.root["assets"] as? [[String: Any]] ?? []
            guard let index = assets.firstIndex(where: { $0["id"] as? String == clip.assetID })
            else { return }
            assets[index]["cameraTrack"] = nil
            $0.root["assets"] = assets
        }
        rebuild()
    }

    func attachCameraToSelectedClip() {
        guard let clip = project?.clips.first(where: { $0.id == selectedClipID }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mutate { $0.attachCamera(url, to: clip.assetID) }
        rebuild()
    }

    func setCameraVisible(_ visible: Bool) {
        guard let clip = project?.clips.first(where: { $0.id == selectedClipID }) else { return }
        mutate { $0.setCameraVisible(visible, for: clip.assetID) }
        rebuild()
    }

    func setWebcamLayout(_ value: String) {
        mutate { $0.webcamLayout = value }
        rebuild()
    }

    func setWebcamSize(_ value: Double) {
        mutate { $0.webcamSize = value }
        rebuild()
    }

    func setWebcamPosition(_ axis: String, value: Double) {
        mutate {
            var position = $0.webcamPosition
            position[axis] = value
            $0.webcamPosition = position
        }
        rebuild()
    }

    func setWebcamMaskShape(_ shape: String) {
        mutate { $0.webcamMaskShape = shape }
        rebuild()
    }

    func setWebcamMirrored(_ mirrored: Bool) {
        mutate { $0.webcamMirrored = mirrored }
        rebuild()
    }

    func setCursorHighlight(_ enabled: Bool) {
        mutate { $0.cursorHighlight = enabled }
        rebuild()
    }

    func addFullCamera() {
        guard
            let segment = previewMetadata?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            }), project?.assets.first(where: { $0.id == segment.clip.assetID })?.cameraTrack != nil
        else { return }
        let start = segment.rulerTime(at: playhead) * 1000
        let end = min(
            (segment.clip.timelineStart + segment.clip.duration) * 1000,
            start + 2000)
        mutate { $0.addCameraFullscreen(startMs: start, endMs: end) }
        rebuild()
    }

    func removeFullCamera(_ id: String) {
        mutate { $0.removeCameraFullscreen(id) }
        rebuild()
    }

    func undo() {
        guard let previous = undoHistory.popLast(), let current = project else { return }
        redoHistory.append(current)
        project = previous
        persistCurrentProject()
        rebuild()
    }

    func redo() {
        guard let next = redoHistory.popLast(), let current = project else { return }
        undoHistory.append(current)
        project = next
        persistCurrentProject()
        rebuild()
    }

    func mutate(_ action: (inout VideoProject) -> Void) {
        guard var project else { return }
        undoHistory.append(project)
        if undoHistory.count > Self.maximumUndoSteps {
            undoHistory.removeFirst(undoHistory.count - Self.maximumUndoSteps)
        }
        redoHistory.removeAll()
        action(&project)
        self.project = project
        persistCurrentProject()
    }

    private func persistCurrentProject() {
        hasUnsavedEdits = true
        if let remoteClient, let project { remoteClient.persist(project); return }
        guard var project, let url = project.fileURL else { return }
        do {
            try project.save(to: url)
            self.project = project
            hasUnsavedEdits = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateFocusPreview() {
        if let remoteClient { remoteFocusReady = false; remoteClient.refresh(); return }
        focusPreviewTask?.cancel()
        focusSeeker?.reset()
        focusPlayer.currentItem?.cancelPendingSeeks()
        focusPreviewGeneration += 1
        let version = focusPreviewGeneration
        focusPlayer.pause()
        focusPreviewReady = false
        guard var source = project, let editingZoomID,
            source.zooms.contains(where: { $0.id == editingZoomID }),
            !source.clips.isEmpty
        else {
            focusPlayer.replaceCurrentItem(with: nil)
            return
        }
        source.root["zoomRanges"] = []
        focusPreviewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(40))
                let preview = try await previewBuilder(source)
                try Task.checkCancellation()
                guard version == focusPreviewGeneration else { return }
                let item = AVPlayerItem(asset: preview.composition)
                item.videoComposition = preview.videoComposition
                focusPlayer.replaceCurrentItem(with: item)
                await focusPlayer.seek(
                    to: CMTime(seconds: playhead, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                guard version == focusPreviewGeneration else { return }
                focusPreviewReady = true
                focusSeeker?.request(CMTime(seconds: playhead, preferredTimescale: 60000))
            } catch is CancellationError {
            } catch {
                guard version == focusPreviewGeneration else { return }
                self.editingZoomID = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func rebuild(refreshFocusPreview: Bool = true) {
        if let remoteClient, let project { remoteClient.persist(project); return }
        rebuildTask?.cancel()
        isRebuildingPreview = false
        generation += 1
        let version = generation
        player.pause()
        if let editingZoomID,
            project?.zooms.contains(where: { $0.id == editingZoomID }) != true
        {
            self.editingZoomID = nil
        }
        if refreshFocusPreview { updateFocusPreview() }
        guard let project, !project.clips.isEmpty else {
            resetPreviewSeeks()
            pipeline = nil
            player.replaceCurrentItem(with: nil)
            playhead = 0
            return
        }
        isRebuildingPreview = true
        rebuildTask = Task {
            defer {
                if version == generation { isRebuildingPreview = false }
            }
            do {
                try await Task.sleep(for: .milliseconds(40))
                let next = try await previewBuilder(project)
                try Task.checkCancellation()
                guard version == generation else { return }
                pipeline = next
                let item = AVPlayerItem(asset: next.composition)
                item.videoComposition = next.videoComposition
                item.audioMix = next.audioMix
                resetPreviewSeeks()
                player.replaceCurrentItem(with: item)
                seek(to: min(playhead, next.duration))
            } catch is CancellationError {
            } catch {
                guard version == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
    func applyRemote(_ value: StudioUIVideoState, preserveProject: Bool) throws {
        guard !isClosed else { return }
        if let state = value.project {
            let next = try state.value
            if !preserveProject { project = next; hasUnsavedEdits = false }
            remoteMetadata = try value.preview.map { try VideoPreviewMetadata($0, project: next) }
            if selectedClipID == nil { selectedClipID = project?.clips.first?.id }
        } else if !preserveProject {
            project = nil; remoteMetadata = nil
        }
        remotePlaybackRate = value.rate
        if value.rate != 0 || !preserveProject { playhead = value.playhead }
        isRebuildingPreview = value.preparing
        audioStatus = value.audioStatus; isTranscribing = value.transcribing
        silenceClipID = value.silenceClipID; silentRanges = value.silentRanges
        recentProjects = value.recent.map(\.value)
        if let error = value.error { errorMessage = error }
    }

    func remoteAction(_ name: String, object: [String: Any] = [:]) -> Bool {
        guard let remoteClient else { return false }
        var fields = object; fields["action"] = name
        if let selectedClipID { fields["clipID"] = selectedClipID }
        remoteClient.send("studio.ui.video.action", object: fields)
        return true
    }

    func pausePlayback() {
        if let remoteClient {
            remoteClient.send("studio.ui.video.pause")
        } else {
            player.pause(); focusPlayer.pause()
        }
    }

    func attachRemoteCommand(_ request: VideoEditorService.OpenRequest) async throws {
        guard let remoteClient else { throw ExtensionPeerError.unavailable }
        try await remoteClient.attach(request)
    }

    func mountRemoteCommand(_ request: VideoEditorService.OpenRequest) async throws {
        guard let remoteClient else { throw ExtensionPeerError.unavailable }
        try await remoteClient.mounted(request)
    }

    func exportRemoteAudio(to url: URL, settings: VideoAudioDeliverySettings) -> Bool {
        guard let remoteClient else { return false }
        let exporter = self.exporter
        exporter.start(to: url) { progress in
            let report = try await remoteClient.exportAudio(to: url, settings: settings) { value in
                progress(value)
            }
            exporter.setAudioReport(report, for: url)
        }
        return true
    }

    func runRemoteFile(_ operation: @escaping @MainActor () async throws -> Void) {
        importTask?.cancel()
        importTask = Task { [weak self] in
            do { try await operation() } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func stopAndWait() async {
        let owned = [
            rebuildTask, openTask, focusPreviewTask, audioTask, transcriptionTask, importTask,
        ].compactMap { $0 }
        close()
        for task in owned { await task.value }
    }

}
