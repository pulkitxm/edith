import Foundation
import Observation

@MainActor
@Observable
public final class ContentLoad {
    public private(set) var state: ContentLoadingState = .loading
    public private(set) var isRunning = false
    public private(set) var hasContent = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cancelOperation: (() -> Void)?

    public init() {}

    public var isRefreshing: Bool { isRunning && hasContent }

    @discardableResult
    public func begin(preservingContent: Bool = true) -> UInt64 {
        cancelOperation?()
        cancelOperation = nil
        generation &+= 1
        isRunning = true
        errorMessage = nil
        hasContent = preservingContent && hasContent
        state = hasContent ? .content : .loading
        return generation
    }

    public func isCurrent(_ request: UInt64) -> Bool {
        request == generation && isRunning && !Task.isCancelled
    }

    public func complete(_ request: UInt64, empty: Bool = false) {
        guard isCurrent(request) else { return }
        isRunning = false
        cancelOperation = nil
        hasContent = !empty
        state = empty ? .empty : .content
        errorMessage = nil
    }

    public func fail(_ request: UInt64, message: String, offline: Bool = false) {
        guard isCurrent(request) else { return }
        isRunning = false
        cancelOperation = nil
        errorMessage = message
        state = hasContent ? .content : offline ? .offline : .error
    }

    public func fail(_ request: UInt64, error: Error) {
        if error is CancellationError || Task.isCancelled {
            cancel(request)
        } else {
            fail(
                request, message: error.localizedDescription,
                offline: (error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    public func cancel(_ request: UInt64? = nil) {
        if let request, request != generation { return }
        cancelOperation?()
        cancelOperation = nil
        generation &+= 1
        isRunning = false
        state = hasContent ? .content : .cancelled
    }

    public func setContent(empty: Bool = false) {
        let request = begin()
        complete(request, empty: empty)
    }

    public func perform<Value: Sendable>(
        preservingContent: Bool = true,
        operation: @escaping @Sendable () async throws -> Value,
        apply: @MainActor (Value) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let request = begin(preservingContent: preservingContent)
        let task = Task.detached(priority: .userInitiated, operation: operation)
        cancelOperation = { task.cancel() }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(request) else {
                if request == generation, Task.isCancelled { cancel() }
                return
            }
            apply(value)
            complete(request)
        } catch {
            guard request == generation else { return }
            fail(request, error: error)
        }
    }
}
