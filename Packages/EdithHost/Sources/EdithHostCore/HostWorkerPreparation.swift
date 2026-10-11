import Foundation

@MainActor
public final class HostWorkerPreparation {
    public private(set) var isClosed = false
    public private(set) var isPrepared = false
    private var task: Task<Result<Void, Error>, Never>?
    private var running = false
    private var generation = 0

    public init() {}

    public func closeAdmission() { isClosed = true }

    public func prepare(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        isClosed = true
        if isPrepared { return }
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
                do { try await operation(); return .success(()) } catch { return .failure(error) }
            }
            task = selected
        }
        let result = await selected.value
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
