import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class StudioUIVideoClient {
    let id = UUID()
    private weak var model: VideoEditorModel?
    private let facade: StudioUIFacade
    private var revision: String?
    private var created = false
    private var closed = false
    private var pending: StudioUIVideoProject?
    private var pendingOutput: URL?
    private var synchronizing: Task<Void, Never>?
    private var observing: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var dirty = false
    private var conflicted = false
    private var frameGeneration = 0
    private var lastFrameGeneration = -1
    private var previewBytes: Data?
    private var projectBytes: Data?

    init(model: VideoEditorModel, facade: StudioUIFacade) {
        self.model = model; self.facade = facade
    }

    deinit { synchronizing?.cancel(); observing?.cancel(); action?.cancel() }

    func create() {
        action?.cancel()
        action = Task { [weak self] in
            guard let self else { return }
            do {
                let handle: StudioUIResource = try await facade.read(
                    created ? "studio.ui.video.reset" : "studio.ui.video.create",
                    object: ["id": id.uuidString])
                created = true
                try await receive(handle, preserveProject: false)
                observe()
            } catch { fail(error) }
        }
    }

    func startProject(_ urls: [URL]) {
        action?.cancel()
        action = Task { [weak self] in
            guard let self else { return }
            do {
                let handle: StudioUIResource = try await facade.read(
                    created ? "studio.ui.video.reset" : "studio.ui.video.create",
                    object: ["id": id.uuidString])
                created = true
                try await receive(handle, preserveProject: false)
                await importMedia(urls)
            } catch { fail(error) }
        }
    }

    func open(_ url: URL) {
        action?.cancel()
        action = Task { [weak self] in
            guard let self else { return }
            do {
                if created {
                    let _: [String: String] = try await facade.read(
                        "studio.ui.video.close", object: ["id": id.uuidString])
                        ;
                    created = false
                }
                let handle: StudioUIResource = try await facade.perform(
                    "studio.ui.video.open", object: ["id": id.uuidString, "path": url.path])
                created = true
                try await receive(handle, preserveProject: false)
                observe()
            } catch { fail(error) }
        }
    }

    func attach(_ request: VideoEditorService.OpenRequest) async throws {
        let handle: StudioUIResource = try await facade.read(
            "studio.ui.video.attach", object: ["id": id.uuidString, "requestID": request.requestID])
        created = true
        try await receive(handle, preserveProject: false)
        try await frame()
        observe()
    }

    func mounted(_ request: VideoEditorService.OpenRequest) async throws {
        guard created, !closed, revision == request.revision, model?.remoteFrame != nil else {
            throw StudioUIOperationFailure(
                message: "The requested editor has not rendered its project.")
        }
        let _: [String: String] = try await facade.read(
            "studio.ui.video.mounted",
            object: ["id": id.uuidString, "requestID": request.requestID])
    }

    func persist(_ project: VideoProject) {
        guard created, !closed else { return }
        do { pending = try StudioUIVideoProject(project); dirty = true } catch {
            fail(error); return
        }
        guard synchronizing == nil, !conflicted else { return }
        synchronizing = Task { [weak self] in
            guard let self else { return }
            defer { synchronizing = nil }
            do {
                try await Task.sleep(for: .milliseconds(40))
                while let next = pending, !closed {
                    pending = nil
                    let output = pendingOutput; pendingOutput = nil
                    let uploaded = try await facade.upload(next)
                    var object: [String: Any] = [
                        "id": id.uuidString, "project": try facade.object(uploaded),
                    ]
                    if let revision { object["revision"] = revision }
                    if let output { object["output"] = output.path }
                    let handle: StudioUIResource = try await facade.perform(
                        "studio.ui.video.update", object: object)
                    try await receive(handle, preserveProject: pending != nil)
                    dirty = pending != nil
                    try await frame()
                }
            } catch {
                if !Task.isCancelled { conflicted = true; fail(error) }
            }
        }
    }

    func save(_ project: VideoProject, to url: URL) {
        pendingOutput = url
        persist(project)
    }

    func importMedia(_ urls: [URL]) async {
        do {
            if !created {
                let handle: StudioUIResource = try await facade.read(
                    "studio.ui.video.create", object: ["id": id.uuidString])
                created = true; try await receive(handle, preserveProject: false)
            }
            let handle: StudioUIResource = try await facade.perform(
                "studio.ui.video.import", object: ["id": id.uuidString, "paths": urls.map(\.path)])
            try await receive(handle, preserveProject: false)
            observe()
        } catch { fail(error) }
    }

    func send(_ operation: String, object: [String: Any] = [:]) {
        guard created, !closed else { return }
        frameGeneration += 1
        action?.cancel()
        action = Task { [weak self] in
            guard let self else { return }
            do {
                var fields = object; fields["id"] = id.uuidString
                let handle: StudioUIResource = try await facade.read(operation, object: fields)
                try await receive(handle, preserveProject: dirty)
                try await frame()
            } catch { fail(error) }
        }
    }

    func refresh(discard: Bool = false) {
        if discard {
            pending = nil; dirty = false; conflicted = false; synchronizing?.cancel();
            synchronizing = nil
        }
        send("studio.ui.video.snapshot")
    }

    func export(
        to url: URL, gif: Bool, quality: VideoExportQuality, settings: VideoDeliverySettings,
        fps: Int, width: Int, loop: Bool, progress: @escaping @MainActor (Double) -> Void
    ) async throws -> VideoDeliveryReport? {
        guard created, !closed else { throw ExtensionEngineError.unavailable }
        let object: [String: Any] = [
            "id": id.uuidString, "format": gif ? "gif" : "video", "output": url.path,
            "settings": try facade.object(settings), "quality": quality.rawValue, "fps": fps,
            "width": width, "loop": loop,
        ]
        if gif {
            let _: [String: String] = try await facade.perform(
                "studio.ui.video.export", object: object, progress: progress)
            return nil
        }
        return try await facade.perform(
            "studio.ui.video.export", object: object, progress: progress)
    }

    func exportAudio(
        to url: URL, settings: VideoAudioDeliverySettings,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> VideoAudioDeliveryReport {
        guard created, !closed else { throw ExtensionEngineError.unavailable }
        return try await facade.perform(
            "studio.ui.video.export",
            object: [
                "id": id.uuidString,
                "format": "audio", "output": url.path, "settings": try facade.object(settings),
            ], progress: progress)
    }

    func close() {
        guard !closed else { return }; closed = true
        synchronizing?.cancel(); observing?.cancel(); action?.cancel()
        synchronizing = nil; observing = nil; action = nil
        if created {
            Task {
                let _: [String: String]? = try? await facade.read(
                    "studio.ui.video.close", object: ["id": id.uuidString])
            }
        }
    }

    private func receive(_ handle: StudioUIResource, preserveProject: Bool) async throws {
        let value: StudioUIVideoState = try await facade.download(handle)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if !conflicted { revision = value.revision }
        let bytes = try value.preview.map { try JSONEncoder().encode($0) }
        if bytes != previewBytes || value.project?.document != projectBytes {
            frameGeneration += 1; previewBytes = bytes; projectBytes = value.project?.document
        }
        try model?.applyRemote(value, preserveProject: preserveProject)
    }

    private func frame() async throws {
        guard let model, model.previewMetadata != nil, !closed else { return }
        let generation = frameGeneration
        let focus = model.editingZoomID != nil
        let handle: StudioUIResource = try await facade.read(
            "studio.ui.video.frame",
            object: [
                "id": id.uuidString,
                "time": max(0, model.playhead), "focus": focus,
            ])
        let value: StudioUIVideoFrame = try await facade.download(handle)
        try Task.checkCancellation()
        guard !closed, generation == frameGeneration else { return }
        if focus {
            model.remoteFocusFrame = value.image?.image; model.remoteFocusReady = value.image != nil
        } else {
            model.remoteFrame = value.image?.image
        }
        if value.rate != 0 { model.playhead = value.playhead }
        model.remotePlaybackRate = value.rate
        lastFrameGeneration = generation
    }

    private func observe() {
        guard observing == nil else { return }
        observing = Task { [weak self] in
            guard let self else { return }
            var refreshed = ContinuousClock.now
            while !Task.isCancelled, !closed {
                do {
                    if refreshed.duration(to: .now) >= .milliseconds(500), synchronizing == nil {
                        let handle: StudioUIResource = try await facade.read(
                            "studio.ui.video.snapshot", object: ["id": id.uuidString])
                        try await receive(handle, preserveProject: dirty)
                        refreshed = .now
                    }
                    if model?.playbackRate != 0 || lastFrameGeneration != frameGeneration {
                        try await frame()
                    }
                    try await Task.sleep(
                        for: model?.playbackRate == 0 ? .milliseconds(150) : .milliseconds(33))
                } catch {
                    if Task.isCancelled || closed { return }
                    fail(error)
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard !closed, !Task.isCancelled else { return }
        model?.errorMessage = error.localizedDescription
    }
}
