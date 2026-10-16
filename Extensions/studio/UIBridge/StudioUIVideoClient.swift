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
    private var commandsSuspended = false
    private var pending: StudioUIVideoProject?
    private var pendingOutput: URL?
    private var synchronizing: Task<Void, Never>?
    private var observing: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private nonisolated let owned = StudioTaskOwner()
    private var relinkPanel: NSOpenPanel?
    private var dirty = false
    private var conflicted = false

    init(model: VideoEditorModel, facade: StudioUIFacade) {
        self.model = model; self.facade = facade
    }

    deinit { synchronizing?.cancel(); observing?.cancel(); action?.cancel() }

    func create() {
        guard !commandsSuspended else { return }
        action?.cancel()
        action = owned.start { [weak self] in
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
        guard !commandsSuspended else { return }
        action?.cancel()
        action = owned.start { [weak self] in
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
        guard !commandsSuspended else { return }
        action?.cancel()
        action = owned.start { [weak self] in
            guard let self else { return }
            do {
                if created {
                    let _: [String: String] = try await facade.read(
                        "studio.ui.video.close", object: ["id": id.uuidString])
                        ;
                    created = false
                }
                let info: StudioUIVideoOpenInfo = try await facade.read(
                    "studio.ui.video.preflight", object: ["id": id.uuidString, "path": url.path])
                let document = try info.project.value
                var replacements: [String: String] = [:]
                for asset in document.assets where info.missingAssetIDs.contains(asset.id) {
                    let panel = NSOpenPanel()
                    panel.message = "Locate \(asset.label) to open this project"
                    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
                    relinkPanel = panel
                    let replacement: URL? = await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            panel.begin { response in
                                continuation.resume(returning: response == .OK ? panel.url : nil)
                            }
                        }
                    } onCancel: {
                        self.owned.enqueue { panel.cancel(nil) }
                    }
                    relinkPanel = nil
                    try Task.checkCancellation()
                    if let replacement { replacements[asset.id] = replacement.path }
                }
                let handle: StudioUIResource = try await facade.perform(
                    "studio.ui.video.open",
                    object: [
                        "id": id.uuidString, "path": url.path, "revision": info.revision,
                        "replacements": replacements,
                    ])
                created = true
                try await receive(handle, preserveProject: false)
                observe()
            } catch { fail(error) }
        }
    }

    func attach(_ request: VideoEditorService.OpenRequest) async throws {
        guard !commandsSuspended else { throw ExtensionEngineError.unavailable }
        let handle: StudioUIResource = try await facade.read(
            "studio.ui.video.attach", object: ["id": id.uuidString, "requestID": request.requestID])
        created = true
        try await receive(handle, preserveProject: false)
        observe()
    }

    func mounted(_ request: VideoEditorService.OpenRequest) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while let model, !model.previewReady, model.errorMessage == nil, !closed,
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard created, !closed, !commandsSuspended, revision == request.revision,
            model?.previewReady == true
        else {
            throw StudioUIOperationFailure(
                message: "The requested editor has not rendered its project.")
        }
        let _: [String: String] = try await facade.read(
            "studio.ui.video.mounted",
            object: ["id": id.uuidString, "requestID": request.requestID])
    }

    func persist(_ project: VideoProject) {
        guard created, !closed, !commandsSuspended else { return }
        do { pending = try StudioUIVideoProject(project); dirty = true } catch {
            fail(error); return
        }
        guard synchronizing == nil, !conflicted else { return }
        synchronizing = owned.start { [weak self] in
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
                }
            } catch {
                if !Task.isCancelled { conflicted = true; fail(error) }
            }
        }
    }

    func save(_ project: VideoProject, to url: URL) {
        guard !commandsSuspended else { return }
        pendingOutput = url
        persist(project)
    }

    func importMedia(_ urls: [URL]) async {
        guard !commandsSuspended else { return }
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
        guard created, !closed, !commandsSuspended else { return }
        action?.cancel()
        action = owned.start { [weak self] in
            guard let self else { return }
            do {
                var fields = object; fields["id"] = id.uuidString
                let handle: StudioUIResource = try await facade.read(operation, object: fields)
                try await receive(handle, preserveProject: dirty)
            } catch { fail(error) }
        }
    }

    func refresh(discard: Bool = false) {
        guard !commandsSuspended else { return }
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
        guard created, !closed, !commandsSuspended else { throw ExtensionEngineError.unavailable }
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
        guard created, !closed, !commandsSuspended else { throw ExtensionEngineError.unavailable }
        return try await facade.perform(
            "studio.ui.video.export",
            object: [
                "id": id.uuidString,
                "format": "audio", "output": url.path, "settings": try facade.object(settings),
            ], progress: progress)
    }

    func close() {
        guard !closed else { return }; closed = true
        owned.shutdown()
        synchronizing?.cancel(); observing?.cancel(); action?.cancel(); relinkPanel?.cancel(nil)
        synchronizing = nil; observing = nil; action = nil
        if created {
            facade.cleanup("studio.ui.video.close", object: ["id": id.uuidString])
        }
    }

    func suspendCommands() {
        commandsSuspended = true
        owned.shutdown()
        synchronizing?.cancel(); observing?.cancel(); action?.cancel(); relinkPanel?.cancel(nil)
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        await owned.shutdownAndWait()
    }

    func waitForPendingWork() async { await owned.waitForPendingWork() }

    func closeAndWait() async {
        close()
        await owned.shutdownAndWait()
    }

    private func receive(_ handle: StudioUIResource, preserveProject: Bool) async throws {
        let value: StudioUIVideoState = try await facade.download(handle)
        try Task.checkCancellation()
        guard !closed, !commandsSuspended else { throw CancellationError() }
        if !conflicted { revision = value.revision }
        try model?.applyRemote(value, preserveProject: preserveProject)
    }

    private func observe() {
        guard observing == nil else { return }
        observing = owned.start { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !closed {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard synchronizing == nil else { continue }
                    let handle: StudioUIResource = try await facade.read(
                        "studio.ui.video.snapshot", object: ["id": id.uuidString])
                    try await receive(handle, preserveProject: dirty)
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
