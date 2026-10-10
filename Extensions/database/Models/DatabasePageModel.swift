import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class DatabasePageModel {
    enum Readiness: Hashable {
        case checking
        case repairing
        case ready
        case failed(String)
    }

    private(set) var readiness = Readiness.checking
    private let ensureReady: @Sendable () async throws -> Void
    private let repairService: @Sendable () async throws -> Void
    let loading = ContentLoad()

    init(
        ensureReady: @escaping @Sendable () async throws -> Void = {
            _ = try await DatabaseWorkerClient().send(.connectionList(.init()))
        },
        repairService: @escaping @Sendable () async throws -> Void = {
            try await DatabaseWorkerClient.restart()
        }
    ) {
        self.ensureReady = ensureReady
        self.repairService = repairService
    }

    var failureDetail: String? {
        guard case let .failed(detail) = readiness else { return nil }
        return detail
    }

    func refresh() async {
        await run(.checking, operation: ensureReady)
    }

    func repair() async {
        await run(.repairing, operation: repairService)
    }

    private func run(
        _ pendingState: Readiness,
        operation: @Sendable () async throws -> Void
    ) async {
        let requestGeneration = loading.begin(preservingContent: false)
        defer { if Task.isCancelled { loading.cancel(requestGeneration) } }
        readiness = pendingState
        do {
            try await operation()
            guard loading.isCurrent(requestGeneration) else { return }
            readiness = .ready
            loading.complete(requestGeneration)
            announce("Database tools are ready.")
        } catch is CancellationError {
            guard loading.owns(requestGeneration) else { return }
            loading.cancel(requestGeneration)
            readiness = .failed("The database readiness check was cancelled.")
            announce("Database tools need attention.")
        } catch {
            guard loading.isCurrent(requestGeneration) else { return }
            loading.fail(requestGeneration, message: Self.message(for: error))
            readiness = .failed(Self.message(for: error))
            announce("Database tools need attention.")
        }
    }

    private func announce(_ message: String) {
        AccessibilityAnnouncement.post(message)
    }

    private static func message(for error: Error) -> String {
        "Database could not open its local metadata. Retry to reopen it."
    }
}
