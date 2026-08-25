import Foundation

public struct StartupPhase: Sendable {
    public let name: String
    fileprivate let operation: @MainActor @Sendable () -> Void

    public init(name: String, operation: @escaping @MainActor @Sendable () -> Void) {
        self.name = name
        self.operation = operation
    }
}

@MainActor
public final class StartupCoordinator {
    private let suspend: @Sendable () async -> Void
    private var generation: UInt = 0
    private var task: Task<Void, Never>?

    public init(suspend: @escaping @Sendable () async -> Void = { await Task.yield() }) {
        self.suspend = suspend
    }

    public func start(_ phases: [StartupPhase]) {
        task?.cancel()
        generation &+= 1
        let currentGeneration = generation
        let suspend = suspend
        task = Task { [weak self] in
            for phase in phases {
                await suspend()
                guard !Task.isCancelled, let self, generation == currentGeneration else { return }
                PerformanceTrace.measure(.startup, phase.name) {
                    phase.operation()
                }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    public func waitForCurrent() async {
        await task?.value
    }
}
