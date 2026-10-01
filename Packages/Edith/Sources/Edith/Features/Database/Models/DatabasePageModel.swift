import EdithDatabase
import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class DatabasePageModel {
    enum Readiness: Hashable {
        case checking
        case installing(Double)
        case repairing
        case ready
        case failed(String)
    }

    private(set) var readiness = Readiness.checking
    private let ensureReady: @Sendable () async throws -> Void
    private let repairService: @Sendable () async throws -> Void
    private let preparePack: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    private var generation = UUID()

    init(
        ensureReady: @escaping @Sendable () async throws -> Void = {
            try await DatabaseBrokerClientCoordinator.shared.ensureReady()
        },
        repairService: @escaping @Sendable () async throws -> Void = {
            try await DatabaseBrokerServiceRepairer().repair()
            try await DatabaseBrokerClientCoordinator.shared.ensureReady()
        },
        preparePack:
            @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = {
                report in
                _ = try await DatabasePackInstaller.live { fraction in
                    report(fraction)
                }.install()
            }
    ) {
        self.ensureReady = ensureReady
        self.repairService = repairService
        self.preparePack = preparePack
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
        let requestGeneration = UUID()
        generation = requestGeneration
        readiness = pendingState
        do {
            try await preparePack { fraction in
                Task { @MainActor in
                    guard self.generation == requestGeneration, self.readiness != .ready else {
                        return
                    }
                    self.readiness = .installing(fraction)
                }
            }
            guard generation == requestGeneration, !Task.isCancelled else { return }
            try await operation()
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .ready
            announce("Database tools are ready.")
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            readiness = .failed("The database readiness check was cancelled.")
            announce("Database tools need attention.")
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            readiness = .failed(Self.message(for: error))
            announce("Database tools need attention.")
        }
    }

    private func announce(_ message: String) {
        AccessibilityAnnouncement.post(message)
    }

    private static func message(for error: Error) -> String {
        if let pack = error as? DatabasePackInstallError {
            switch pack {
            case .checksumMismatch:
                return "The database pack checksum did not match the published digest."
            case .signatureRejected:
                return "The database pack signature was rejected."
            case .signatureUnavailable:
                return "The database pack signature could not be checked."
            case .archiveInvalid:
                return "The database pack archive could not be read."
            case .downloadFailed:
                return "The database pack could not be downloaded."
            case .developmentBuild:
                return "This development build installs the database pack from the local build."
            }
        }
        guard let availability = error as? DatabaseBrokerAvailabilityError else {
            return "The local database service could not be reached."
        }
        switch availability {
        case .readinessTimedOut:
            return "The local database service did not become ready in time."
        case .versionTransitionTimedOut:
            return "The local database service could not finish updating."
        case .unsafePeer:
            return "The local database service could not be verified."
        case .outcomeUnknown:
            return "The local database service could not confirm its readiness."
        case .unavailable:
            return "The local database service is unavailable."
        }
    }
}
