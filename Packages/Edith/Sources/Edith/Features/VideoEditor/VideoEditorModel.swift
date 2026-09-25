import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class VideoEditorModel {
    private struct SessionMedia: Sendable {
        let cameraPath: String?
        let cameraOffset: Int
        let microphonePath: String?
        let microphoneOffset: Int
    }
    var project: VideoProject?
    var selectedClipID: String?
    var playhead = 0.0
    var zoomDepth = 4
    var regionSpeed = 2.0
    var zoomDuration = 2.0
    var focusX = 0.5
    var focusY = 0.5
    var editingZoomID: String?
    var captionText = ""
    var captionDuration = 3.0
    var isRendering = false
    var isTranscribing = false
    var gifFPS = 15
    var gifWidth = 0
    var gifLoop = true
    var loopPlayback = false
    var errorMessage: String?
    var permissionSettingsURL: URL?
    var lastExportURL: URL?
    var recentProjects: [VideoProject.Listing] = []

    let player = AVPlayer()
    let focusPlayer = AVPlayer()
    private(set) var focusPreviewReady = false
    private(set) var pipeline: VideoRenderPipeline?
    private var observer: Any?
    private var generation = 0
    private var focusPreviewGeneration = 0
    private var undoHistory: [VideoProject] = []
    private var redoHistory: [VideoProject] = []

    var duration: Double { pipeline?.duration ?? 0 }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }

    init() {
        refreshRecentProjects()
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.playhead = time.seconds
            }
        }
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        focusPlayer.pause()
        focusPlayer.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func newProject() {
        player.pause()
        project = .create()
        selectedClipID = nil
        editingZoomID = nil
        undoHistory.removeAll()
        redoHistory.removeAll()
        saveInLibrary()
        rebuild()
    }

    func startProject(with urls: [URL]) {
        newProject()
        Task { await addMedia(urls) }
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
        do {
            var document = try VideoProject.open(url)
            document.relinkMediaNextToProject()
            for asset in document.assets
            where !FileManager.default.fileExists(atPath: asset.url.path) {
                let panel = NSOpenPanel()
                panel.message = "Locate \(asset.label) to open this project"
                panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                if panel.runModal() == .OK, let replacement = panel.url {
                    document.relinkMedia(assetID: asset.id, to: replacement)
                }
            }
            if url.path.hasPrefix(VideoProject.openScreenLibraryURL.path + "/") {
                document.fileURL = nil
            }
            project = document
            selectedClipID = project?.clips.first?.id
            editingZoomID = nil
            undoHistory.removeAll()
            redoHistory.removeAll()
            generation += 1
            let version = generation
            player.pause()
            player.replaceCurrentItem(with: nil)
            pipeline = nil
            Task {
                let prepared = await document.probingMissingMedia()
                guard version == generation, project?.id == prepared.id else { return }
                project = prepared
                if prepared.fileURL == nil { saveInLibrary() }
                rebuild()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshRecentProjects() {
        recentProjects = VideoProject.listProjects()
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
                Task { await self.addMedia(urls) }
            }
        }
    }

    private func addMedia(_ urls: [URL]) async {
        do {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                if type?.conforms(to: .image) == true {
                    let movie = try await Task.detached(priority: .utility) {
                        try await VideoStillMedia.create(from: url)
                    }.value
                    try await addFile(movie, label: url.lastPathComponent, sourceImage: url)
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
        let start =
            pipeline?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })?.rulerTime(at: playhead) ?? 0
        mutate { $0.addAudio(url, duration: duration, at: start * 1000) }
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
        _ url: URL, label: String? = nil, sourceImage: URL? = nil
    ) async throws {
        if project == nil {
            project = .create(
                title: sourceImage?.deletingPathExtension().lastPathComponent
                    ?? url.deletingPathExtension().lastPathComponent)
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
            let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw VideoRenderPipeline.RenderError.noVideo }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = size.applying(transform)
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
                label: label, sourceImage: sourceImage)
            if let session, let cameraPath = session.cameraPath,
                let assetID = $0.assets.last?.id
            {
                $0.attachCamera(
                    URL(fileURLWithPath: cameraPath), to: assetID,
                    offsetMs: session.cameraOffset)
            }
            if let microphoneURL, let microphoneDuration,
                microphoneDuration.isFinite, microphoneDuration > 0,
                let clipStart = $0.clips.last?.timelineStart
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
        guard var project else { return }
        do {
            try project.save(to: url)
            self.project = project
            refreshRecentProjects()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveInLibrary() {
        guard var project else { return }
        do {
            try FileManager.default.createDirectory(
                at: VideoProject.libraryURL, withIntermediateDirectories: true)
            let url = VideoProject.libraryURL.appendingPathComponent("\(project.id).openscreen")
            try project.save(to: url)
            self.project = project
            refreshRecentProjects()
        } catch { errorMessage = error.localizedDescription }
    }

    func export(gif: Bool, quality: VideoExportQuality = .source) {
        guard let pipeline, let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = "\(project.title).\(gif ? "gif" : "mp4")"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.isRendering = true
                Task {
                    do {
                        if gif {
                            try pipeline.exportGIF(
                                to: url, fps: self.gifFPS, maxWidth: self.gifWidth,
                                loop: self.gifLoop)
                        } else {
                            let render: VideoRenderPipeline
                            if let dimension = quality.maxDimension {
                                render = try await VideoRenderPipeline.make(
                                    project: project, maxDimension: dimension)
                            } else {
                                render = pipeline
                            }
                            try await render.exportMP4(to: url)
                        }
                        self.lastExportURL = url
                    } catch { self.errorMessage = error.localizedDescription }
                    self.isRendering = false
                }
            }
        }
    }

    func togglePlayback() {
        if player.rate == 0 {
            if playhead >= duration - 0.1 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
            focusPlayer.seek(to: CMTime(seconds: playhead, preferredTimescale: 600))
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(duration, seconds))
        playhead = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        if focusPreviewReady {
            focusPlayer.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func splitAtPlayhead() {
        guard
            let segment = pipeline?.segments.first(where: {
                playhead >= $0.outputStart && playhead < $0.outputEnd
            })
        else { return }
        let sourceTime = segment.sourceTime(at: playhead)
        mutate { $0.split(clipID: segment.clip.id, at: sourceTime) }
        rebuild()
    }

    func skipAtPlayhead() {
        guard
            let segment = pipeline?.segments.first(where: {
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
            let segment = pipeline?.segments.first(where: {
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
        if let segment = pipeline?.segments.first(where: {
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
        guard let pipeline else { return 0 }
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
            let segments = pipeline?.segments.filter({ $0.clip.id == clipID }),
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
            seek(to: outputTime(forRulerTime: (zoom.startMs + zoom.endMs) / 2000))
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
        zoomDuration = duration
        guard let editingZoomID else { return }
        mutate { $0.updateZoom(editingZoomID, duration: duration) }
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
            let segment = pipeline?.segments.first(where: {
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
            let segment = pipeline?.segments.first(where: {
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
        guard let clip = project?.clips.first(where: { $0.id == selectedClipID }),
            let asset = project?.assets.first(where: { $0.id == clip.assetID })
        else { return }
        isTranscribing = true
        Task {
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
            let segment = pipeline?.segments.first(where: {
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

    func addOverlay(_ type: String) {
        guard
            let segment = pipeline?.segments.first(where: {
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
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url)
                }.value
                guard let data else { return }
                let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                mutate {
                    $0.addOverlay(
                        type: type, startMs: start, endMs: start + 2500,
                        x: focusX, y: focusY,
                        content: "data:\(mime);base64,\(data.base64EncodedString())")
                }
                rebuild()
            }
            return
        }
        mutate {
            $0.addOverlay(
                type: type, startMs: start, endMs: start + 2500,
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
    }

    func setAspectRatio(_ ratio: String) {
        mutate { $0.aspectRatio = ratio }
        rebuild()
    }

    func setPadding(_ value: Double) {
        mutate { $0.padding = value }
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
            let segment = pipeline?.segments.first(where: {
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

    private func mutate(_ action: (inout VideoProject) -> Void) {
        guard var project else { return }
        undoHistory.append(project)
        redoHistory.removeAll()
        action(&project)
        self.project = project
        persistCurrentProject()
    }

    private func persistCurrentProject() {
        guard var project, let url = project.fileURL else { return }
        do {
            try project.save(to: url)
            self.project = project
        } catch { errorMessage = error.localizedDescription }
    }

    private func updateFocusPreview() {
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
        Task {
            do {
                let preview = try await VideoRenderPipeline.make(project: source)
                guard version == focusPreviewGeneration else { return }
                let item = AVPlayerItem(asset: preview.composition)
                item.videoComposition = preview.videoComposition
                focusPlayer.replaceCurrentItem(with: item)
                await focusPlayer.seek(
                    to: CMTime(seconds: playhead, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                guard version == focusPreviewGeneration else { return }
                focusPreviewReady = true
            } catch {
                guard version == focusPreviewGeneration else { return }
                self.editingZoomID = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuild(refreshFocusPreview: Bool = true) {
        generation += 1
        let version = generation
        let oldTime = playhead
        player.pause()
        if let editingZoomID,
            project?.zooms.contains(where: { $0.id == editingZoomID }) != true
        {
            self.editingZoomID = nil
        }
        if refreshFocusPreview { updateFocusPreview() }
        guard let project, !project.clips.isEmpty else {
            pipeline = nil
            player.replaceCurrentItem(with: nil)
            playhead = 0
            return
        }
        Task {
            do {
                let next = try await VideoRenderPipeline.make(project: project)
                guard version == generation else { return }
                pipeline = next
                let item = AVPlayerItem(asset: next.composition)
                item.videoComposition = next.videoComposition
                item.audioMix = next.audioMix
                player.replaceCurrentItem(with: item)
                seek(to: min(oldTime, next.duration))
            } catch {
                guard version == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
