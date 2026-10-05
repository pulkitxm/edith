import AppKit
import EdithKit
import Foundation

@MainActor
final class QuinjetSessionBridge {
    static let shared = QuinjetSessionBridge()

    private final class Attachment {
        let token: UUID
        weak var model: QuinjetPageModel?
        weak var router: WindowRouter?

        init(token: UUID, model: QuinjetPageModel, router: WindowRouter?) {
            self.token = token
            self.model = model
            self.router = router
        }
    }

    private var attachments: [Attachment] = []
    private var observer: NSObjectProtocol?

    func install() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestQuinjetSessionOperation,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.receive(info) }
            })
    }

    func attach(_ model: QuinjetPageModel, token: UUID, router: WindowRouter? = nil) {
        detach(token: token)
        attachments.append(Attachment(token: token, model: model, router: router))
    }

    func detach(token: UUID) {
        attachments.removeAll { $0.token == token || $0.model == nil }
    }

    func model(for router: WindowRouter?) -> QuinjetPageModel? {
        attachment(for: router)?.model
    }

    private func attachment(for router: WindowRouter?) -> Attachment? {
        attachments.removeAll { $0.model == nil }
        if let router, let attachment = attachments.last(where: { $0.router === router }) {
            return attachment
        }
        return attachments.last
    }

    private func receive(_ info: [AnyHashable: Any]) {
        let requestID = info[QuinjetSessionIPC.requestIDKey] as? String ?? ""
        guard let raw = info[QuinjetSessionIPC.operationKey] as? String,
            let operation = QuinjetSessionOperation(rawValue: raw)
        else {
            fail(.operationFailed("The Quinjet session operation is invalid."), requestID)
            return
        }
        guard let attachment = attachment(for: WindowRouter.forKeyWindow()),
            let model = attachment.model
        else {
            fail(.pageUnavailable, requestID)
            return
        }
        let request = QuinjetSessionRequest(
            operation: operation,
            session: info[QuinjetSessionIPC.sessionKey] as? String,
            worktreePath: info[QuinjetSessionIPC.worktreePathKey] as? String)
        if operation == .focus || operation == .create {
            if let router = attachment.router,
                let window = NSApp.windows.first(where: { WindowRouter.router(for: $0) === router })
            {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                MainWindow.open()
            }
        }
        Task {
            do {
                let result = try await model.performSessionOperation(request)
                let data = try JSONEncoder().encode(result)
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw QuinjetSessionError.operationFailed(
                        "Edith could not encode the Quinjet session result.")
                }
                IPC.post(
                    IPC.Name.quinjetSessionOperationResult,
                    userInfo: [
                        QuinjetSessionIPC.requestIDKey: requestID,
                        QuinjetSessionIPC.okKey: true,
                        QuinjetSessionIPC.payloadKey: payload,
                    ])
            } catch let error as QuinjetSessionError {
                fail(error, requestID)
            } catch {
                fail(.operationFailed(error.localizedDescription), requestID)
            }
        }
    }

    private func fail(_ error: QuinjetSessionError, _ requestID: String) {
        IPC.post(
            IPC.Name.quinjetSessionOperationResult,
            userInfo: [
                QuinjetSessionIPC.requestIDKey: requestID,
                QuinjetSessionIPC.okKey: false,
                QuinjetSessionIPC.errorCodeKey: error.code,
                QuinjetSessionIPC.errorKey: error.localizedDescription,
            ])
    }
}
