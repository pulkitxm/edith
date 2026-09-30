import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class VideoEditorOpenBridge {
    struct Presentation {
        let request: VideoEditorService.OpenRequest
        let model: VideoEditorModel
    }

    static let shared = VideoEditorOpenBridge()
    private(set) var pending: Presentation?
    weak var activeEditor: VideoEditorModel?
    private var request: VideoEditorService.OpenRequest?
    private var deadline: Date?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private let reply: @MainActor ([String: Any]) -> Void
    private let present: @MainActor () -> Void

    init(
        reply: @escaping @MainActor ([String: Any]) -> Void = {
            IPC.post(IPC.Name.videoEditorOpenResult, userInfo: $0)
        },
        present: @escaping @MainActor () -> Void = {
            SharedDefaults.store.set(
                MainDestination.studio.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
            MainWindow.open()
        }
    ) {
        self.reply = reply
        self.present = present
    }

    func install() {
        guard observer == nil else { return }
        observer = IPC.observe(IPC.Name.requestVideoEditorOpen) { [weak self] info in
            MainActor.assumeIsolated {
                guard let request = VideoEditorService.OpenRequest(payload: info),
                    let deadline = info["deadline"] as? Double
                else { return }
                self?.receive(request, deadline: Date(timeIntervalSince1970: deadline))
            }
        }
    }

    func receive(_ next: VideoEditorService.OpenRequest, deadline: Date) {
        guard request == nil else {
            fail(
                next, code: "editor_busy",
                message: "Another project is opening. Retry when it finishes.")
            return
        }
        guard deadline > Date(), deadline.timeIntervalSinceNow <= 121 else {
            fail(next, code: "open_timeout", message: "The project-open request expired.")
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
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.request == next else { return }
            self.finishFailure(
                next, code: "open_timeout",
                message: "The native editor did not mount this project in time.")
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let model = VideoEditorModel()
            do {
                try await model.loadCommandProject(next)
                try Task.checkCancellation()
                guard self.request == next else { model.close(); return }
                guard activeEditor?.blocksCommandOpen != true else {
                    throw VideoEditorService.Failure(
                        "editor_busy", "The editor has unsaved changes or an active task.")
                }
                pending = Presentation(request: next, model: model)
                present()
            } catch {
                model.close()
                guard self.request == next else { return }
                finishFailure(
                    next, code: (error as? VideoEditorService.Failure)?.code ?? "open_failed",
                    message: error.localizedDescription)
            }
        }
    }

    func mounted(_ presentation: Presentation) {
        let next = presentation.request
        guard request == next, pending?.model === presentation.model else { return }
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
        } catch {
            finishFailure(
                next, code: (error as? VideoEditorService.Failure)?.code ?? "open_failed",
                message: error.localizedDescription)
        }
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
        pending?.model.close()
        clear()
        fail(request, code: code, message: message)
    }

    private func fail(_ request: VideoEditorService.OpenRequest, code: String, message: String) {
        var payload: [String: Any] = request.payload
        payload["ok"] = false
        payload["code"] = code
        payload["error"] = message
        reply(payload)
    }
}
