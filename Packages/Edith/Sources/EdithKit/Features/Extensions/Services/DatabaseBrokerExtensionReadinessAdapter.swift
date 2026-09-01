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
            return .ready("The authenticated local database broker is ready.")
        } catch is CancellationError {
            return .loading("The local database broker readiness check was cancelled.")
        } catch let error as DatabaseBrokerAvailabilityError {
            return readiness(for: error)
        } catch {
            return .failed("The local database broker readiness check failed.")
        }
    }

    private func readiness(
        for error: DatabaseBrokerAvailabilityError
    ) -> ExtensionAdapterReadiness {
        switch error {
        case .readinessTimedOut:
            .failed("The local database broker did not become ready in time.")
        case .versionTransitionTimedOut:
            .failed("The local database broker could not finish updating in time.")
        case .unsafePeer:
            .failed("The local database broker failed peer authentication.")
        case .outcomeUnknown:
            .failed("The local database broker could not confirm its readiness outcome.")
        case .unavailable:
            .failed("The local database broker is unavailable.")
        }
    }
}
