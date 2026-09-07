import EdithDatabase

struct DatabaseBrokerExtensionReadinessAdapter: Sendable {
    private let ensureReady: @Sendable () async throws -> Void

    init(
        ensureReady: @escaping @Sendable () async throws -> Void
    ) {
        self.ensureReady = ensureReady
    }

    init(
        coordinator: DatabaseBrokerClientCoordinator = .shared
    ) {
        self.init {
            try await coordinator.ensureReady()
        }
    }

    func readiness() async -> ExtensionAdapterReadiness {
        do {
            try await ensureReady()
            return .ready("The secure local database service is ready.")
        } catch is CancellationError {
            return .failed("The database service check was cancelled.")
        } catch let error as DatabaseBrokerAvailabilityError {
            return readiness(for: error)
        } catch {
            return .failed("The database service check failed.")
        }
    }

    private func readiness(
        for error: DatabaseBrokerAvailabilityError
    ) -> ExtensionAdapterReadiness {
        switch error {
        case .readinessTimedOut:
            .failed("The database service did not become ready in time.")
        case .versionTransitionTimedOut:
            .failed("The database service could not finish updating in time.")
        case .unsafePeer:
            .failed("The database service could not verify the local app.")
        case .outcomeUnknown:
            .failed("The database service could not confirm its current state.")
        case .unavailable:
            .failed("The database service is unavailable.")
        }
    }
}
