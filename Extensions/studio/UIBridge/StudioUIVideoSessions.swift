import AVFoundation
import EdithExtensionSupport
import EdithStudio
import Foundation

@MainActor final class StudioUIVideoSessions {
    private final class Session {
        let model: VideoEditorModel
        var accessed = ContinuousClock.now
        var generator: AVAssetImageGenerator?
        var pipeline: VideoRenderPipeline?
        var focusGenerator: AVAssetImageGenerator?
        var focusDocument: Data?
        init(_ model: VideoEditorModel) { self.model = model }
        func cancelFrames() {
            generator?.cancelAllCGImageGeneration(); focusGenerator?.cancelAllCGImageGeneration()
            generator = nil; focusGenerator = nil; pipeline = nil; focusDocument = nil
        }
    }
    private var sessions: [UUID: Session] = [:]
    private var timer: Task<Void, Never>?
    private var stopped = false
    private static let fields: [String: Set<String>] = [
        "studio.ui.video.reset": ["id"],
        "studio.ui.video.create": ["id"], "studio.ui.video.open": ["id", "path"],
        "studio.ui.video.snapshot": ["id"], "studio.ui.video.close": ["id"],
        "studio.ui.video.update": ["id", "project", "revision", "output"],
        "studio.ui.video.frame": ["id", "time", "focus"],
        "studio.ui.video.seek": ["id", "time"], "studio.ui.video.play": ["id"],
        "studio.ui.video.pause": ["id"], "studio.ui.video.import": ["id", "paths"],
        "studio.ui.video.action": ["id", "action", "clipID", "assetID", "denoise"],
        "studio.ui.video.export": [
            "id", "format", "output", "settings", "quality", "fps", "width", "loop",
        ],
        "studio.ui.video.attach": ["id", "requestID"],
        "studio.ui.video.mounted": ["id", "requestID"],
    ]

    deinit { timer?.cancel() }

    func execute(
        _ operation: String, payload: Data, resources: StudioUIResources,
        work: StudioUILongOperations
    ) async throws -> Data {
        guard !stopped, let allowed = Self.fields[operation],
            payload.count <= StudioCommands.maximumRequestBytes,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed), let text = object["id"] as? String,
            let id = UUID(uuidString: text)
        else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        if operation == "studio.ui.video.create" || operation == "studio.ui.video.open" {
            guard sessions[id] == nil, sessions.count < 8 else {
                throw ExtensionPeerError.unavailable
            }
            let session = Session(VideoEditorModel())
            sessions[id] = session
            startTimer()
            if operation == "studio.ui.video.create" {
                session.model.newProject()
                return try snapshot(session, resources: resources)
            }
            let url = try Self.path(object, "path")
            return try encoder.encode(
                work.start { _ in
                    let request = try VideoEditorService.prepareOpen(url)
                    try await session.model.loadCommandProject(request)
                    return try self.snapshot(session, resources: resources)
                })
        }
        if operation == "studio.ui.video.attach" {
            guard sessions[id] == nil, sessions.count < 8,
                let requestID = object["requestID"] as? String,
                let pending = VideoEditorOpenBridge.shared.pending,
                pending.request.requestID == requestID
            else { throw ExtensionPeerError.invalidRequest }
            let session = Session(pending.model)
            sessions[id] = session
            startTimer()
            return try snapshot(session, resources: resources)
        }
        guard let session = sessions[id] else { throw ExtensionPeerError.unavailable }
        session.accessed = .now
        let model = session.model
        switch operation {
        case "studio.ui.video.snapshot": return try snapshot(session, resources: resources)
        case "studio.ui.video.reset": model.newProject(); session.cancelFrames()
        case "studio.ui.video.close":
            sessions[id] = nil; session.cancelFrames(); await model.stopAndWait()
            return Data("{}".utf8)
        case "studio.ui.video.mounted":
            guard let requestID = object["requestID"] as? String,
                let pending = VideoEditorOpenBridge.shared.pending,
                pending.request.requestID == requestID, pending.model === model
            else { throw ExtensionPeerError.invalidRequest }
            try model.verifyCommandProject(pending.request)
            VideoEditorOpenBridge.shared.mounted(pending)
            return Data("{}".utf8)
        case "studio.ui.video.update":
            let project: StudioUIVideoProject = try Self.consume(
                object["project"], resources: resources)
            var document = try project.value
            try document.validateVideoSettings(); try document.validateOutputCaptions()
            for url in VideoEditorService.sourceURLs(document, includeSidecars: false) {
                _ = try StudioCommands.localPath(url.path)
            }
            if let source = document.fileURL {
                _ = try StudioCommands.localPath(source.path)
                let snapshot = try VideoEditorService.readProject(source)
                let revision = snapshot.revision.fingerprint.digest.map {
                    String(format: "%02x", $0)
                }.joined()
                document.fileRevision = snapshot.project.fileRevision
                guard object["revision"] as? String == revision else {
                    throw VideoEditorService.Failure(
                        "project_changed",
                        "The project changed on disk. Refresh before saving your edits.")
                }
            }
            let target =
                try (object["output"] as? String).map(StudioCommands.localPath) ?? document.fileURL
            if let target { document.fileURL = target }
            let updated = document
            return try encoder.encode(
                work.start { _ in
                    var next = updated
                    if let target { try next.save(to: target) }
                    let pipeline =
                        next.clips.isEmpty
                        ? nil : try await VideoRenderPipeline.make(project: next, previewOnly: true)
                    try Task.checkCancellation()
                    let player: AVPlayer?
                    if let pipeline {
                        let item = AVPlayerItem(asset: pipeline.composition)
                        item.videoComposition = pipeline.videoComposition;
                        item.audioMix = pipeline.audioMix
                        player = AVPlayer(playerItem: item)
                    } else {
                        player = nil
                    }
                    model.acceptExternalProject(next, prepared: pipeline, playbackPlayer: player)
                    session.cancelFrames()
                    return try self.snapshot(session, resources: resources)
                })
        case "studio.ui.video.frame":
            guard let time = object["time"] as? Double, time.isFinite, time >= 0,
                let focus = object["focus"] as? Bool
            else { throw ExtensionPeerError.invalidRequest }
            guard let pipeline = model.pipeline, let project = model.project else {
                return try encoder.encode(
                    resources.store(
                        encoder.encode(
                            StudioUIVideoFrame(
                                image: nil, playhead: model.playhead, rate: model.player.rate))))
            }
            let generator: AVAssetImageGenerator
            if focus {
                var source = project; source.root["zoomRanges"] = []
                let bytes = try StudioUIVideoProject(source).document
                if session.focusDocument != bytes || session.focusGenerator == nil {
                    let native = try await VideoRenderPipeline.make(
                        project: source, previewOnly: true)
                    session.focusGenerator?.cancelAllCGImageGeneration()
                    let value = AVAssetImageGenerator(asset: native.composition)
                    value.videoComposition = native.videoComposition
                    value.requestedTimeToleranceBefore = .zero;
                    value.requestedTimeToleranceAfter = .zero
                    session.focusGenerator = value; session.focusDocument = bytes
                }
                guard let value = session.focusGenerator else {
                    throw ExtensionPeerError.unavailable
                }; generator = value
            } else {
                if session.pipeline?.composition !== pipeline.composition
                    || session.generator == nil
                {
                    session.generator?.cancelAllCGImageGeneration()
                    let value = AVAssetImageGenerator(asset: pipeline.composition)
                    value.videoComposition = pipeline.videoComposition
                    value.requestedTimeToleranceBefore = .zero;
                    value.requestedTimeToleranceAfter = .zero
                    session.generator = value; session.pipeline = pipeline
                }
                guard let value = session.generator else { throw ExtensionPeerError.unavailable };
                generator = value
            }
            let position = model.player.rate == 0 ? time : model.playhead
            let selected = min(
                max(0, position),
                max(0, pipeline.duration - pipeline.videoComposition.frameDuration.seconds))
            let frame = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: selected, preferredTimescale: 60_000))
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try Task.checkCancellation()
            let value = try StudioUIVideoFrame(
                image: StudioUIImageData(frame.image), playhead: position, rate: model.player.rate)
            return try encoder.encode(resources.store(encoder.encode(value)))
        case "studio.ui.video.seek":
            guard let time = object["time"] as? Double, time.isFinite,
                (0...model.duration).contains(time)
            else { throw ExtensionPeerError.invalidRequest }
            model.seek(to: time)
        case "studio.ui.video.play": model.togglePlayback()
        case "studio.ui.video.pause": model.player.pause(); model.focusPlayer.pause()
        case "studio.ui.video.import":
            guard let paths = object["paths"] as? [String], !paths.isEmpty,
                paths.count <= StudioCommands.maximumPaths
            else { throw ExtensionPeerError.invalidRequest }
            let urls = try paths.map(StudioCommands.localPath)
            return try encoder.encode(
                work.start { _ in
                    await model.addMedia(urls)
                    try Task.checkCancellation()
                    return try self.snapshot(session, resources: resources)
                })
        case "studio.ui.video.action":
            guard let action = object["action"] as? String else {
                throw ExtensionPeerError.invalidRequest
            }
            if let clipID = object["clipID"] as? String {
                guard model.project?.clips.contains(where: { $0.id == clipID }) == true else {
                    throw ExtensionPeerError.invalidRequest
                }
                model.selectedClipID = clipID
            }
            switch action {
            case "captions": model.generateCaptions()
            case "silence": model.detectSilence()
            case "audio":
                guard let assetID = object["assetID"] as? String,
                    let denoise = object["denoise"] as? Bool,
                    model.project?.assets.contains(where: { $0.id == assetID }) == true
                else { throw ExtensionPeerError.invalidRequest }
                model.processAudio(assetID: assetID, denoise: denoise)
            case "detach":
                guard let clipID = object["clipID"] as? String else {
                    throw ExtensionPeerError.invalidRequest
                }
                model.detachAudio(clipID: clipID)
            default: throw ExtensionPeerError.invalidRequest
            }
        case "studio.ui.video.export":
            guard let project = model.project, let format = object["format"] as? String,
                ["video", "gif", "audio"].contains(format)
            else { throw ExtensionPeerError.invalidRequest }
            let output = try Self.path(object, "output")
            guard !project.protectsMedia(at: output) else {
                throw StudioError.failed(
                    "Choose an export destination different from your project and source media.")
            }
            if format == "audio" {
                let settings: VideoAudioDeliverySettings = try Self.decode(object["settings"])
                return try encoder.encode(
                    work.start { progress in
                        let pipeline = try await VideoRenderPipeline.make(project: project)
                        let report = try await pipeline.exportAudio(
                            to: output, settings: settings, overwrite: true, progress: progress)
                        return try JSONEncoder().encode(report)
                    })
            }
            let settings: VideoDeliverySettings = try Self.decode(object["settings"])
            guard let raw = object["quality"] as? String,
                let quality = VideoExportQuality(rawValue: raw),
                let fps = object["fps"] as? Int, (1...120).contains(fps),
                let width = object["width"] as? Int, (0...16_384).contains(width),
                let loop = object["loop"] as? Bool
            else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(
                work.start { progress in
                    let pipeline = try await VideoRenderPipeline.make(
                        project: project, maxDimension: quality.maxDimension)
                    if format == "gif" {
                        try await pipeline.exportGIF(
                            to: output, fps: fps, maxWidth: width, loop: loop, progress: progress)
                        return Data("{}".utf8)
                    }
                    let report = try await pipeline.export(
                        to: output, settings: settings, overwrite: true, progress: progress)
                    return try JSONEncoder().encode(report)
                })
        default: throw ExtensionPeerError.invalidRequest
        }
        return try snapshot(session, resources: resources)
    }

    func stopAndWait() async {
        stopped = true; timer?.cancel(); timer = nil
        let owned = Array(sessions.values); sessions.removeAll()
        for session in owned { session.cancelFrames(); await session.model.stopAndWait() }
    }

    private func snapshot(_ session: Session, resources: StudioUIResources) throws -> Data {
        let model = session.model
        let revision = try model.project?.fileURL.map {
            try VideoEditorService.prepareOpen($0).revision
        }
        let state = try StudioUIVideoState(
            project: model.project.map(StudioUIVideoProject.init),
            preview: model.pipeline.map(StudioUIVideoPreview.init), revision: revision,
            playhead: model.playhead,
            rate: model.player.rate, preparing: model.isPreparingPreview, error: model.errorMessage,
            audioStatus: model.audioStatus, transcribing: model.isTranscribing,
            silenceClipID: model.silenceClipID,
            silentRanges: model.silentRanges,
            recent: model.recentProjects.map(StudioUIState.Project.init))
        let encoder = JSONEncoder()
        return try encoder.encode(resources.store(encoder.encode(state)))
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                for (id, session) in self.sessions
                where session.accessed.duration(to: .now) >= .seconds(60) {
                    self.sessions[id] = nil; session.cancelFrames();
                    await session.model.stopAndWait()
                }
            }
        }
    }

    private nonisolated static func path(_ object: [String: Any], _ key: String) throws -> URL {
        guard let value = object[key] as? String else { throw ExtensionPeerError.invalidRequest }
        return try StudioCommands.localPath(value)
    }
    private static func decode<Value: Decodable>(_ object: Any?) throws -> Value {
        guard let object else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(
            Value.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private static func consume<Value: Decodable>(_ object: Any?, resources: StudioUIResources)
        throws -> Value
    {
        let handle: StudioUIResource = try decode(object)
        return try JSONDecoder().decode(Value.self, from: resources.consume(handle))
    }
}
