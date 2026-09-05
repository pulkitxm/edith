import Foundation

public enum AgentFileTransferLocation: Codable, Equatable, Sendable {
    case local
    case remote(Machine)

    public var name: String {
        switch self {
        case .local: "This Mac"
        case let .remote(machine): machine.name
        }
    }
}

public struct AgentFileTransferRequest: Codable, Sendable {
    public static let operation = "machine.files.transfer"
    public let plan: RemoteTransferPlan
    public let source: AgentFileTransferLocation
    public let destination: AgentFileTransferLocation
    public let confirmsReplacement: Bool
    public let moving: Bool

    public init(
        plan: RemoteTransferPlan, source: AgentFileTransferLocation,
        destination: AgentFileTransferLocation, confirmsReplacement: Bool, moving: Bool = false
    ) {
        self.plan = plan
        self.source = source
        self.destination = destination
        self.confirmsReplacement = confirmsReplacement
        self.moving = moving
    }
}

extension AgentTaskClient {
    public func transferFiles(
        _ request: AgentFileTransferRequest,
        progress: RemoteTransferOperationExecution.Progress? = nil
    ) async throws -> RemoteTransferOutcome {
        let publication = FileTransferProgressPublication(progress: progress)
        let submission = AgentTaskSubmission(
            operation: AgentFileTransferRequest.operation,
            title: "Transfer \(request.plan.items.count) files to \(request.destination.name)",
            payload: try AgentPayload.encode(request))
        do {
            let data = try await run(submission) { publication.receive($0.text) }
            await publication.finish()
            return try AgentPayload.decode(RemoteTransferOutcome.self, from: data)
        } catch let failure as AgentTaskFailure {
            await publication.finish()
            guard failure.snapshot.failureCode == "filesIncomplete", let result = failure.result
            else { throw failure }
            return try AgentPayload.decode(RemoteTransferOutcome.self, from: result)
        } catch {
            await publication.finish()
            throw error
        }
    }
}

private final class FileTransferProgressPublication: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: RemoteTransferOperationExecution.Progress?
    private var pending: Task<Void, Never>?

    init(progress: RemoteTransferOperationExecution.Progress?) { self.progress = progress }

    func receive(_ text: String) {
        guard let progress, text.hasPrefix("files:") else { return }
        let parts = text.split(separator: ":")
        guard parts.count == 3, let processed = Int(parts[1]), let total = Int(parts[2]) else {
            return
        }
        lock.withLock {
            let previous = pending
            pending = Task {
                await previous?.value
                await progress(processed, total)
            }
        }
    }

    func finish() async { await lock.withLock { pending }?.value }
}
