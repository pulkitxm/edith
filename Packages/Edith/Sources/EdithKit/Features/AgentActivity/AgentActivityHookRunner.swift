import Foundation

public struct AgentActivityHookRunner: Sendable {
    public typealias Perform = @Sendable (String, Data) async throws -> Data
    private let perform: Perform
    private let interval: Duration

    public init(
        interval: Duration = .milliseconds(250),
        perform: @escaping Perform = {
            try await AgentClient.shared.performInternalAsync($0, payload: $1, timeout: 1.5)
        }
    ) {
        self.perform = perform
        self.interval = interval
    }

    public func run(_ event: AgentActivityEvent) async -> AgentApprovalChoice? {
        var token: AgentApprovalToken?
        do {
            try Task.checkCancellation()
            let payload = try AgentPayload.encode(event)
            guard payload.count <= AgentActivityParser.maximumEventBytes else { return nil }
            let data = try await perform(AgentActivityOperation.ingest, payload)
            let receipt = try AgentPayload.decode(AgentActivityReceipt.self, from: data)
            guard event.provider.supportsPermissionApprovals, event.permissionRequest,
                let received = receipt.token,
                let expires = receipt.expiresAt, expires > Date()
            else { return nil }
            token = received
            let deadline = ContinuousClock.now.advanced(by: .seconds(118))
            while ContinuousClock.now < deadline, Date() < expires {
                try Task.checkCancellation()
                let reply = try await perform(
                    AgentActivityOperation.poll, AgentPayload.encode(received))
                let result = try AgentPayload.decode(AgentApprovalResult.self, from: reply)
                if !result.pending { return Date() < expires ? result.choice : nil }
                try await Task.sleep(for: interval)
            }
        } catch {}
        if let token {
            _ = try? await perform(AgentActivityOperation.cancel, AgentPayload.encode(token))
        }
        return nil
    }
}
