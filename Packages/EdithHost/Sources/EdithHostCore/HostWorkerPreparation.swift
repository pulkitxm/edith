import Foundation

@MainActor
public final class HostWorkerPreparation {
    public enum Failure: Error { case mismatchedOperation, exhaustedRetries }
    public private(set) var isClosed = false
    public private(set) var isPrepared = false
    private var task: Task<Result<Void, Error>, Never>?
    private var running = false
    private var operation: String?
    private var requests: [UUID: Task<Result<Void, Error>, Never>] = [:]
    private var outcomeOperations: [UUID: String] = [:]

    public init() {}

    public func begin(
        token: UUID = UUID(), operation: String = "disable",
        _ action: @escaping @MainActor () async throws -> Void
    ) throws -> Task<Result<Void, Error>, Never> {
        isClosed = true
        guard operation == "disable" || operation == "applicationQuit" else {
            throw Failure.mismatchedOperation
        }
        if let request = requests[token] {
            guard outcomeOperations[token] == operation else { throw Failure.mismatchedOperation }
            return request
        }
        let recoveringQuit =
            self.operation == "applicationQuit" && operation == "disable"
            && !running && !isPrepared
        guard self.operation == nil || self.operation == operation || recoveringQuit else {
            throw Failure.mismatchedOperation
        }
        guard requests.count < 64 else { throw Failure.exhaustedRetries }
        self.operation = operation
        let selected: Task<Result<Void, Error>, Never>
        if isPrepared {
            selected = Task { .success(()) }
        } else if running, let task {
            selected = task
        } else {
            running = true
            selected = Task {
                let result: Result<Void, Error>
                do { try await action(); result = .success(()) } catch { result = .failure(error) }
                self.running = false
                if case .success = result { self.isPrepared = true }
                return result
            }
            task = selected
        }
        requests[token] = selected
        outcomeOperations[token] = operation
        return selected
    }

    public func prepare(
        token: UUID = UUID(), operation: String = "disable",
        _ action: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await begin(token: token, operation: operation, action).value.get()
    }

    public func join() async throws {
        if let task { try await task.value.get() }
    }
}
