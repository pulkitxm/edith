import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class VideoEditorOpenBridge {
    @MainActor final class Presentation {
        let request: VideoEditorService.OpenRequest
        let model: VideoEditorModel
        private weak var owner: StudioModel?
        private var claimed = false

        init(request: VideoEditorService.OpenRequest, model: VideoEditorModel) {
            self.request = request
            self.model = model
        }

        func claim(for owner: StudioModel) -> Bool {
            if claimed { return self.owner === owner }
            self.owner = owner
            claimed = true
            return true
        }

        func close(for owner: StudioModel) {
            guard self.owner === owner else { return }
            self.owner = nil
            model.close()
        }
    }

    static var shared = VideoEditorOpenBridge()
    private(set) var pending: Presentation?
    weak var activeEditor: VideoEditorModel?
    private var request: VideoEditorService.OpenRequest?
    private var deadline: Date?
    private var openWait: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var retiredModels: [UUID: Task<Void, Never>] = [:]
    private var commandsSuspended = false
    private nonisolated let callbacks = StudioTaskOwner()
    private let reply: @MainActor ([String: Any]) -> Void
    var present: @MainActor () -> Void

    init(
        reply: @escaping @MainActor ([String: Any]) -> Void = {
            _ = $0
        },
        present: @escaping @MainActor () -> Void = {}
    ) {
        self.reply = reply
        self.present = present
    }

    func open(_ next: VideoEditorService.OpenRequest, timeout: Double) async throws {
        guard !commandsSuspended, request == nil, openWait == nil else {
            throw VideoEditorService.Failure("editor_busy", "Another project is opening.")
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                openWait = continuation
                receive(next, deadline: Date().addingTimeInterval(timeout))
            }
        } onCancel: {
            self.callbacks.enqueue {
                guard !self.commandsSuspended, self.request == next else { return }
                if let model = self.pending?.model { self.retire(model) }
                let continuation = self.openWait
                self.openWait = nil
                self.clear()
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    func receive(_ next: VideoEditorService.OpenRequest, deadline: Date) {
        guard !commandsSuspended, request == nil else {
            fail(
                next, code: "editor_busy",
                message: "Another project is opening. Retry when it finishes.",
                completesOpen: request == nil)
            return
        }
        guard deadline > Date(), deadline.timeIntervalSinceNow <= 121 else {
            fail(next, code: "open_timeout", message: "The project-open request expired.")
            return
        }
        guard ownedTasks.count <= 6 else {
            fail(next, code: "editor_busy", message: "Previous editor tasks are still stopping.")
            return
        }
        guard activeEditor?.blocksCommandOpen != true else {
            fail(
                next, code: "editor_busy",
                message: "The editor has unsaved changes or an active task.")
            return
        }
        request = next
        self.deadline = deadline
        timeoutTask = ownTask { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.request == next else { return }
            self.finishFailure(
                next, code: "open_timeout",
                message: "The native editor did not mount this project in time.")
        }
        loadTask = ownTask { [weak self] in
            guard let self else { return }
            let model = VideoEditorModel()
            do {
                try await model.loadCommandProject(next)
                try Task.checkCancellation()
                guard !commandsSuspended, self.request == next else {
                    await model.stopAndWait(); return
                }
                guard activeEditor?.blocksCommandOpen != true else {
                    throw VideoEditorService.Failure(
                        "editor_busy", "The editor has unsaved changes or an active task.")
                }
                pending = Presentation(request: next, model: model)
                present()
            } catch {
                await model.stopAndWait()
                guard !commandsSuspended, self.request == next else { return }
                finishFailure(
                    next, code: (error as? VideoEditorService.Failure)?.code ?? "open_failed",
                    message: error.localizedDescription)
            }
        }
    }

    func mounted(_ presentation: Presentation) {
        let next = presentation.request
        guard !commandsSuspended, request == next, pending?.model === presentation.model else {
            return
        }
        guard let deadline, deadline > Date() else {
            finishFailure(
                next, code: "open_timeout",
                message: "The project-open request expired before the native editor mounted it.")
            return
        }
        do {
            try presentation.model.verifyCommandProject(next)
            activeEditor = presentation.model
            var payload: [String: Any] = next.payload
            payload["ok"] = true
            payload["state"] = "opened"
            payload["version"] = 1
            clear()
            reply(payload)
            openWait?.resume()
            openWait = nil
        } catch {
            finishFailure(
                next, code: (error as? VideoEditorService.Failure)?.code ?? "open_failed",
                message: error.localizedDescription)
        }
    }

    func reject(_ requestID: String, message: String) {
        guard !commandsSuspended, let request, request.requestID == requestID else { return }
        finishFailure(request, code: "editor_busy", message: message)
    }

    func suspendCommands() {
        commandsSuspended = true
        callbacks.shutdown()
        for task in ownedTasks.values { task.cancel() }
        pending?.model.suspendCommands()
        activeEditor?.suspendCommands()
        openWait?.resume(throwing: CancellationError())
        openWait = nil
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        let tasks = Array(ownedTasks.values)
        let retired = Array(retiredModels.values)
        let models = [pending?.model, activeEditor].compactMap { $0 }
        for model in models { await model.suspendCommandsAndWait() }
        for task in tasks { await task.value }
        for task in retired { await task.value }
        await callbacks.shutdownAndWait()
    }

    func shutdown() {
        suspendCommands()
        openWait?.resume(throwing: CancellationError())
        openWait = nil
        if let model = pending?.model { retire(model) }
        if let model = activeEditor { retire(model) }
        activeEditor = nil
        clear()
    }

    func stopAndWait() async {
        await suspendCommandsAndWait()
        shutdown()
        let retired = Array(retiredModels.values)
        for task in retired { await task.value }
    }

    private func retire(_ model: VideoEditorModel) {
        model.close()
        let token = UUID()
        let task = Task { [weak self] in
            await model.stopAndWait()
            self?.retiredModels[token] = nil
        }
        retiredModels[token] = task
    }

    private func ownTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { [weak self] in
            defer { self?.ownedTasks[token] = nil }
            await operation()
        }
        ownedTasks[token] = task
        return task
    }

    private func clear() {
        timeoutTask?.cancel()
        loadTask?.cancel()
        timeoutTask = nil
        loadTask = nil
        request = nil
        deadline = nil
        pending = nil
    }

    private func finishFailure(
        _ request: VideoEditorService.OpenRequest, code: String, message: String
    ) {
        if let model = pending?.model { retire(model) }
        clear()
        fail(request, code: code, message: message)
    }

    private func fail(
        _ request: VideoEditorService.OpenRequest, code: String, message: String,
        completesOpen: Bool = true
    ) {
        var payload: [String: Any] = request.payload
        payload["ok"] = false
        payload["code"] = code
        payload["error"] = message
        reply(payload)
        if completesOpen {
            openWait?.resume(throwing: VideoEditorService.Failure(code, message))
            openWait = nil
        }
    }
}
