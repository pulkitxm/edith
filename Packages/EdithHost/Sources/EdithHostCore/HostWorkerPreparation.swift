import Foundation

@MainActor
public final class HostWorkerPreparation {
    public enum Failure: Error { case mismatchedOperation, exhaustedRetries }
    public private(set) var isClosed = false
    public private(set) var isPrepared = false
    private var task: Task<Result<Void, Error>, Never>?
    private var running = false
    private var generation = 0
    private var operation: String?
    private var outcomes: [UUID: Result<Void, Error>] = [:]
    private var outcomeOperations: [UUID: String] = [:]

    public init() {}

    public func closeAdmission() { isClosed = true }

    public func prepare(
        token: UUID = UUID(), operation: String = "disable",
        _ action: @escaping @MainActor () async throws -> Void
    ) async throws {
        isClosed = true
        guard operation == "disable" || operation == "applicationQuit" else {
            throw Failure.mismatchedOperation
        }
        if let outcome = outcomes[token] {
            guard outcomeOperations[token] == operation else { throw Failure.mismatchedOperation }
            try outcome.get()
            return
        }
        let recoveringQuit =
            self.operation == "applicationQuit" && operation == "disable"
            && !running && !isPrepared
        guard self.operation == nil || self.operation == operation || recoveringQuit else {
            throw Failure.mismatchedOperation
        }
        self.operation = operation
        if isPrepared { return }
        guard outcomes.count < 64 else { throw Failure.exhaustedRetries }
        let selectedGeneration: Int
        let selected: Task<Result<Void, Error>, Never>
        if running, let task {
            selectedGeneration = generation
            selected = task
        } else {
            running = true
            generation += 1
            selectedGeneration = generation
            selected = Task {
                do { try await action(); return .success(()) } catch { return .failure(error) }
            }
            task = selected
        }
        let result = await selected.value
        outcomes[token] = result
        outcomeOperations[token] = operation
        if generation == selectedGeneration {
            running = false
            if case .success = result { isPrepared = true }
        }
        try result.get()
    }

    public func join() async throws {
        if let task { try await task.value.get() }
    }
}
