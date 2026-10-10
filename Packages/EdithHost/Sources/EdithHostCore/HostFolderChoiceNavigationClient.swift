import Foundation

@MainActor
public final class HostFolderChoiceNavigationClient: HostWorkerNavigationClient {
    private struct Pending {
        let completion: (NSDictionary?, NSString?) -> Void
        let deadline: Task<Void, Never>
    }

    private let configuration: HostWorkerConfiguration
    private let available: @MainActor () -> Bool
    private let send: @MainActor (HostWorkerNavigationRequest) throws -> Void
    private let sendCancel: @MainActor (HostWorkerNavigationCancel) throws -> Void
    private var choices: [UUID: Pending] = [:]
    private var invalidated = false

    public override init(
        configuration: HostWorkerConfiguration, available: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (HostWorkerNavigationRequest) throws -> Void,
        cancel: @escaping @MainActor (HostWorkerNavigationCancel) throws -> Void
    ) {
        self.configuration = configuration
        self.available = available
        self.send = send
        sendCancel = cancel
        super.init(configuration: configuration, available: available, send: send, cancel: cancel)
    }

    public override var pendingRequestCount: Int { super.pendingRequestCount + choices.count }

    @objc(chooseFolder:completion:)
    public func chooseFolder(
        _ input: NSDictionary, completion: @escaping (NSDictionary?, NSString?) -> Void
    ) -> NSString? {
        guard input.count == 1, let value = input["presentationID"] as? String,
            let presentation = UUID(uuidString: value), !invalidated, available(),
            !configuration.recoveryOnly, pendingRequestCount < 8
        else { completion(nil, "Folder choice was rejected."); return nil }
        let request = HostWorkerNavigationRequest(
            configuration: configuration, section: "agentActivity", presentationID: presentation,
            location: "settings", folderChoice: true)
        do {
            try request.validate(configuration: configuration)
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.cancelChoice(request.token)
            }
            choices[request.token] = Pending(completion: completion, deadline: deadline)
            do { try send(request) } catch {
                if let pending = choices.removeValue(forKey: request.token) {
                    pending.deadline.cancel()
                    throw error
                }
            }
            return request.token.uuidString as NSString
        } catch { completion(nil, "Folder choice was rejected."); return nil }
    }

    public override func receive(_ reply: HostWorkerNavigationReply) throws {
        try reply.validate(configuration: configuration)
        guard choices[reply.token] != nil else {
            if reply.selectedPath != nil || reply.folderCancelled != nil { return }
            try super.receive(reply)
            return
        }
        guard available(), !invalidated else { cancelChoice(reply.token); return }
        let result = HostFolderChoiceResult(
            selectedPath: reply.selectedPath, cancelled: reply.folderCancelled)
        if reply.ok { try result.validate() }
        guard let pending = choices.removeValue(forKey: reply.token) else { return }
        pending.deadline.cancel()
        pending.completion(
            reply.ok ? result.dictionary : nil, reply.ok ? nil : "Folder choice was rejected.")
    }

    public override func cancelNavigation(_ token: NSString) {
        if let id = UUID(uuidString: token as String) { cancelChoice(id) }
        super.cancelNavigation(token)
    }

    public override func cancelPending() {
        for token in Array(choices.keys) { cancelChoice(token) }
        super.cancelPending()
    }

    public override func invalidate() {
        invalidated = true
        cancelPending()
        super.invalidate()
    }

    private func cancelChoice(_ token: UUID) {
        guard let pending = choices.removeValue(forKey: token) else { return }
        pending.deadline.cancel()
        try? sendCancel(HostWorkerNavigationCancel(token: token, configuration: configuration))
        pending.completion(nil, "Folder choice was cancelled.")
    }
}
