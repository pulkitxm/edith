import EdithCore
import Observation

@MainActor
@Observable
public final class ExtensionReadinessModel {
    public typealias Load = @Sendable () async -> ExtensionLifecycleReport

    public private(set) var report: ExtensionLifecycleReport?
    public private(set) var isRefreshing = false

    private let load: Load
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(load: @escaping Load) {
        self.load = load
    }

    @discardableResult
    public func refresh() -> Task<Void, Never> {
        generation &+= 1
        let requestedGeneration = generation
        refreshTask?.cancel()
        report = nil
        isRefreshing = true
        let load = load
        let task = Task { [weak self] in
            let result = await load()
            guard !Task.isCancelled else { return }
            self?.publish(result, generation: requestedGeneration)
        }
        refreshTask = task
        return task
    }

    public func cancel() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func publish(
        _ result: ExtensionLifecycleReport, generation requestedGeneration: UInt64
    ) {
        guard requestedGeneration == generation else { return }
        report = result
        isRefreshing = false
        refreshTask = nil
    }
}
