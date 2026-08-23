import EdithKit
import Foundation

@MainActor
final class QuinjetSessionBridge {
    static let shared = QuinjetSessionBridge()

    private weak var model: QuinjetPageModel?
    private var observer: NSObjectProtocol?

    func install() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestQuinjetSessionOperation,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.receive(info) }
            })
    }

    func attach(_ model: QuinjetPageModel) {
        self.model = model
    }

    func detach(_ model: QuinjetPageModel) {
        if self.model === model { self.model = nil }
    }

    private func receive(_ info: [AnyHashable: Any]) {
        let requestID = info[QuinjetSessionIPC.requestIDKey] as? String ?? ""
        guard let raw = info[QuinjetSessionIPC.operationKey] as? String,
            let operation = QuinjetSessionOperation(rawValue: raw)
        else {
            fail(.operationFailed("The Quinjet session operation is invalid."), requestID)
            return
        }
        guard let model else {
            fail(.pageUnavailable, requestID)
            return
        }
        let request = QuinjetSessionRequest(
            operation: operation,
            session: info[QuinjetSessionIPC.sessionKey] as? String,
            worktreePath: info[QuinjetSessionIPC.worktreePathKey] as? String)
        if operation == .focus { MainWindow.open() }
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
