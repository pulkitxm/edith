import EdithDatabase
import Foundation
import Observation

struct DatabaseSafetyReviewSession: Identifiable, Equatable {
    let id: UUID
    let preview: DatabaseDestructivePreview
}

struct DatabaseAcceptedMutation: Equatable {
    let connectionID: DatabaseConnectionID
    let serverOperationIdentifier: String
}

@MainActor
@Observable
final class DatabaseWorkspaceModel {
    private(set) var safetyReview: DatabaseSafetyReviewSession?
    private(set) var safetyPhase = DatabaseSafetyReviewPhase.ready
    private(set) var mutationNotice: String?
    private(set) var unresolvedOperationID: DatabaseOperationID?
    private(set) var acceptedMutation: DatabaseAcceptedMutation?

    private let sender: any DatabaseBrokerCommandSending
    private let makeOperationID: @Sendable () -> DatabaseOperationID
    private let makeSessionID: @Sendable () -> UUID
    private let currentDate: @Sendable () -> Date
    private var mutationRequest: DatabaseDestructiveRequest?
    private var reviewSessionID: UUID?
    private var previewGeneration = UUID()
    private var applyGeneration = UUID()
    private var previewOperationID: DatabaseOperationID?
    private var applyOperationID: DatabaseOperationID?
    private var previewTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        makeOperationID: @escaping @Sendable () -> DatabaseOperationID = {
            DatabaseOperationID()
        },
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sender = sender
        self.makeOperationID = makeOperationID
        self.makeSessionID = makeSessionID
        self.currentDate = currentDate
    }

    var hasUnresolvedMutation: Bool {
        unresolvedOperationID != nil
    }

    var hasTrackedMutation: Bool {
        unresolvedOperationID != nil || acceptedMutation != nil
    }

    func requestSafetyReview(for request: DatabaseDestructiveRequest) {
        guard !hasTrackedMutation else {
            mutationNotice =
                "Resolve the active or uncertain mutation before starting another mutation."
            return
        }
        invalidatePreview()
        invalidateApply()
        mutationRequest = request
        reviewSessionID = makeSessionID()
        safetyReview = nil
        safetyPhase = .ready
        mutationNotice = nil
        unresolvedOperationID = nil
        acceptedMutation = nil
        startPreview(request: request)
    }

    func waitForPreview() async {
        await previewTask?.value
    }

    func refreshSafetyPreview() async {
        guard let request = mutationRequest else { return }
        guard !safetyPhase.locksPreviewRefresh else { return }
        startPreview(request: request)
        await previewTask?.value
    }

    func confirmSafetyReview(_ confirmationText: String) {
        guard
            let request = mutationRequest,
            let review = safetyReview,
            safetyPhase == .ready,
            currentDate() < review.preview.expiresAt,
            confirmationText == review.preview.requiredConfirmation.text
        else {
            if let review = safetyReview, currentDate() >= review.preview.expiresAt {
                safetyPhase = .failed(
                    "The preview expired. Create a fresh preview before retrying.")
            }
            return
        }

        invalidateApply()
        let operationID = makeOperationID()
        let generation = applyGeneration
        applyOperationID = operationID
        unresolvedOperationID = operationID
        acceptedMutation = nil
        safetyPhase = .executing
        mutationNotice = nil
        let sender = sender
        let token = review.preview.token
        applyTask = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .mutationApply(
                        DatabaseMutationApplyRequest(
                            mutation: request,
                            token: token,
                            confirmationText: confirmationText,
                            operation: DatabaseOperationContext(operationID: operationID))))
                try Task.checkCancellation()
                self?.finishApply(response, generation: generation, operationID: operationID)
            } catch is CancellationError {
            } catch DatabaseBrokerCommandClientError.outcomeUnknown {
                await self?.reconcileUnknownApply(
                    generation: generation,
                    operationID: operationID)
            } catch {
                self?.failApply(
                    Self.message(for: error),
                    generation: generation,
                    operationID: operationID)
            }
        }
    }

    func cancelSafetyOperation() {
        guard safetyPhase.allowsOperationCancellation else { return }
        if let acceptedMutation {
            cancelAcceptedMutation(acceptedMutation)
            return
        }
        guard let operationID = applyOperationID else {
            dismissSafetyReview()
            return
        }

        invalidateApply()
        let generation = applyGeneration
        unresolvedOperationID = operationID
        safetyPhase = .cancelling
        let sender = sender
        applyTask = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .operationCancel(DatabaseOperationCancelRequest(operationID: operationID)))
                try Task.checkCancellation()
                await self?.finishCancellation(
                    response,
                    generation: generation,
                    operationID: operationID)
            } catch is CancellationError {
            } catch {
                self?.markOutcomeUnknown(
                    "The cancellation outcome could not be confirmed. Check operation status before issuing another mutation.",
                    generation: generation,
                    operationID: operationID)
            }
        }
    }

    func reconcileSafetyOperation() async {
        guard safetyPhase.allowsReconciliation else { return }
        if let acceptedMutation {
            await reconcileAcceptedMutation(acceptedMutation)
            return
        }
        guard let operationID = unresolvedOperationID else { return }
        invalidateApply()
        let generation = applyGeneration
        applyOperationID = operationID
        safetyPhase = .reconciling
        let sender = sender
        applyTask = Task { [weak self] in
            await self?.performReconciliation(
                sender: sender,
                generation: generation,
                operationID: operationID)
        }
        await applyTask?.value
    }

    func dismissSafetyReview() {
        invalidatePreview()
        let preservesUnresolvedOperation = safetyPhase.preservesUnresolvedOperation
        if !preservesUnresolvedOperation {
            invalidateApply()
            mutationRequest = nil
            applyOperationID = nil
            unresolvedOperationID = nil
            acceptedMutation = nil
            mutationNotice = nil
        } else {
            applyTask?.cancel()
            applyTask = nil
            mutationNotice = safetyPhase.message
        }
        safetyReview = nil
        reviewSessionID = nil
        previewOperationID = nil
        if !preservesUnresolvedOperation {
            safetyPhase = .ready
        }
    }

    private func startPreview(request: DatabaseDestructiveRequest) {
        previewTask?.cancel()
        previewGeneration = UUID()
        let generation = previewGeneration
        let operationID = makeOperationID()
        previewOperationID = operationID
        let sender = sender
        previewTask = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .mutationPreview(
                        DatabaseMutationPreviewRequest(
                            mutation: request,
                            operation: DatabaseOperationContext(operationID: operationID))))
                try Task.checkCancellation()
                self?.finishPreview(
                    response,
                    generation: generation,
                    operationID: operationID)
            } catch is CancellationError {
            } catch {
                self?.failPreview(
                    Self.message(for: error),
                    generation: generation,
                    operationID: operationID)
            }
        }
    }

    private func finishPreview(
        _ response: DatabaseBrokerCommandResponse,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard previewGeneration == generation, previewOperationID == operationID else { return }
        defer { previewTask = nil }
        guard let result = response.mutationPreviewResult else {
            safetyPhase = .failed("The broker returned an unexpected preview response.")
            return
        }
        guard
            result.status == .succeeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty,
            let payload = result.payload
        else {
            safetyPhase = .failed(Self.message(for: result))
            return
        }
        let sessionID = reviewSessionID ?? makeSessionID()
        reviewSessionID = sessionID
        safetyReview = DatabaseSafetyReviewSession(id: sessionID, preview: payload.preview)
        safetyPhase = .ready
        mutationNotice = nil
    }

    private func failPreview(
        _ message: String,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard previewGeneration == generation, previewOperationID == operationID else { return }
        previewTask = nil
        safetyPhase = .failed(message)
        mutationNotice = message
    }

    private func finishApply(
        _ response: DatabaseBrokerCommandResponse,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        defer { applyTask = nil }
        guard let result = response.mutationApplyResult else {
            markOutcomeUnknown(
                "The broker returned an unexpected apply response. The mutation was not replayed.",
                generation: generation,
                operationID: operationID)
            return
        }
        guard
            result.status != .partiallySucceeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty
        else {
            markOutcomeUnknown(
                "The broker returned a partial mutation result. Verify its durable outcome before issuing another mutation.",
                generation: generation,
                operationID: operationID)
            return
        }
        guard
            result.status == .succeeded,
            let payload = result.payload
        else {
            safetyPhase = .failed(Self.message(for: result))
            unresolvedOperationID = nil
            mutationNotice = safetyPhase.message
            return
        }
        unresolvedOperationID = nil
        switch payload.disposition {
        case .completed:
            acceptedMutation = nil
            safetyPhase = .succeeded(Self.completionMessage(payload.affectedRecords))
        case .accepted:
            guard
                let serverOperationIdentifier = payload.serverOperationIdentifier,
                !serverOperationIdentifier.isEmpty,
                let connectionID = mutationRequest?.target.connectionID
            else {
                markOutcomeUnknown(
                    "The database accepted the mutation without a trackable operation identifier. Verify database state before issuing another mutation.",
                    generation: generation,
                    operationID: operationID)
                return
            }
            acceptedMutation = DatabaseAcceptedMutation(
                connectionID: connectionID,
                serverOperationIdentifier: serverOperationIdentifier)
            safetyPhase = .accepted(Self.acceptedMessage(serverOperationIdentifier))
        }
        mutationNotice = safetyPhase.message
    }

    private func failApply(
        _ message: String,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        applyTask = nil
        unresolvedOperationID = nil
        acceptedMutation = nil
        safetyPhase = .failed(message)
        mutationNotice = message
    }

    private func reconcileUnknownApply(
        generation: UUID,
        operationID: DatabaseOperationID
    ) async {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        safetyPhase = .reconciling
        await performReconciliation(
            sender: sender,
            generation: generation,
            operationID: operationID)
    }

    private func performReconciliation(
        sender: any DatabaseBrokerCommandSending,
        generation: UUID,
        operationID: DatabaseOperationID
    ) async {
        do {
            let response = try await sender.send(
                .mutationOutcomeGet(
                    DatabaseMutationOutcomeGetRequest(operationID: operationID)))
            try Task.checkCancellation()
            finishReconciliation(
                response,
                generation: generation,
                operationID: operationID)
        } catch is CancellationError {
        } catch {
            markOutcomeUnknown(
                "The mutation outcome is unknown. The apply request was not replayed. Check operation status before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        }
    }

    private func finishReconciliation(
        _ response: DatabaseBrokerCommandResponse,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        applyTask = nil
        guard
            let result = response.mutationOutcomeGetResult,
            result.status == .succeeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty,
            let payload = result.payload
        else {
            markOutcomeUnknown(
                "The mutation outcome is still unknown. The apply request was not replayed.",
                generation: generation,
                operationID: operationID)
            return
        }
        if let outcome = payload.outcome {
            publishReconciledOutcome(
                outcome,
                generation: generation,
                operationID: operationID)
            return
        }
        guard let operation = payload.operation else {
            markOutcomeUnknown(
                "The broker has no durable record for the mutation outcome. The apply request was not replayed.",
                generation: generation,
                operationID: operationID)
            return
        }
        finishReconciledOperation(
            operation,
            generation: generation,
            operationID: operationID)
    }

    private func finishReconciledOperation(
        _ operation: DatabaseOperationRecordSummary,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        switch operation.state {
        case .queued, .running, .cancelling:
            markOutcomeUnknown(
                "The broker reports that the mutation is still active. Check status again before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .succeeded:
            markOutcomeUnknown(
                "The broker reports that the apply command finished, but its mutation result is unavailable. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .partiallySucceeded:
            markOutcomeUnknown(
                "The mutation partially succeeded. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .failed:
            unresolvedOperationID = nil
            safetyPhase = .failed(operation.error?.message ?? "The mutation failed.")
            mutationNotice = safetyPhase.message
        case .cancelled:
            unresolvedOperationID = nil
            safetyPhase = .failed("The mutation was cancelled.")
            mutationNotice = safetyPhase.message
        }
    }

    private func publishReconciledOutcome(
        _ outcome: DatabaseMutationApplyResult,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        unresolvedOperationID = nil
        switch outcome.disposition {
        case .completed:
            acceptedMutation = nil
            safetyPhase = .succeeded(Self.completionMessage(outcome.affectedRecords))
        case .accepted:
            guard
                let identifier = outcome.serverOperationIdentifier,
                !identifier.isEmpty,
                let connectionID = mutationRequest?.target.connectionID
            else {
                markOutcomeUnknown(
                    "The recovered mutation outcome is not trackable. Verify database state before issuing another mutation.",
                    generation: generation,
                    operationID: operationID)
                return
            }
            acceptedMutation = DatabaseAcceptedMutation(
                connectionID: connectionID,
                serverOperationIdentifier: identifier)
            safetyPhase = .accepted(Self.acceptedMessage(identifier))
        }
        mutationNotice = safetyPhase.message
    }

    private func finishCancellation(
        _ response: DatabaseBrokerCommandResponse,
        generation: UUID,
        operationID: DatabaseOperationID
    ) async {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        guard
            let result = response.operationCancelResult,
            result.status == .succeeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty,
            let payload = result.payload,
            payload.operationID == operationID
        else {
            markOutcomeUnknown(
                "The cancellation outcome could not be confirmed. Check operation status before issuing another mutation.",
                generation: generation,
                operationID: operationID)
            return
        }
        switch payload.disposition {
        case .accepted:
            safetyPhase = .reconciling
            await performReconciliation(
                sender: sender,
                generation: generation,
                operationID: operationID)
        case .alreadyFinished:
            if let operation = payload.operation {
                finishReconciledOperation(
                    operation,
                    generation: generation,
                    operationID: operationID)
            } else {
                await performReconciliation(
                    sender: sender,
                    generation: generation,
                    operationID: operationID)
            }
        case .notActive, .notFound:
            markOutcomeUnknown(
                "The broker could not confirm an active operation to cancel. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        }
    }

    private func reconcileAcceptedMutation(
        _ mutation: DatabaseAcceptedMutation
    ) async {
        invalidateApply()
        let generation = applyGeneration
        safetyPhase = .reconciling
        let sender = sender
        let operationID = makeOperationID()
        applyTask = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .mutationStatus(
                        DatabaseMutationStatusRequest(
                            connectionID: mutation.connectionID,
                            serverOperationIdentifier: mutation.serverOperationIdentifier,
                            operation: DatabaseOperationContext(operationID: operationID))))
                try Task.checkCancellation()
                self?.finishAcceptedMutationStatus(
                    response,
                    mutation: mutation,
                    generation: generation)
            } catch is CancellationError {
            } catch {
                self?.markAcceptedOutcomeUnknown(
                    "The accepted mutation status could not be confirmed. Check status again before issuing another mutation.",
                    mutation: mutation,
                    generation: generation)
            }
        }
        await applyTask?.value
    }

    private func cancelAcceptedMutation(
        _ mutation: DatabaseAcceptedMutation
    ) {
        invalidateApply()
        let generation = applyGeneration
        safetyPhase = .cancelling
        let sender = sender
        let operationID = makeOperationID()
        applyTask = Task { [weak self] in
            do {
                let response = try await sender.send(
                    .mutationCancel(
                        DatabaseMutationCancelRequest(
                            connectionID: mutation.connectionID,
                            serverOperationIdentifier: mutation.serverOperationIdentifier,
                            operation: DatabaseOperationContext(operationID: operationID))))
                try Task.checkCancellation()
                self?.finishAcceptedMutationCancellation(
                    response,
                    mutation: mutation,
                    generation: generation)
            } catch is CancellationError {
            } catch {
                self?.markAcceptedOutcomeUnknown(
                    "The accepted mutation cancellation could not be confirmed. Check status before issuing another mutation.",
                    mutation: mutation,
                    generation: generation)
            }
        }
    }

    private func finishAcceptedMutationStatus(
        _ response: DatabaseBrokerCommandResponse,
        mutation: DatabaseAcceptedMutation,
        generation: UUID
    ) {
        guard applyGeneration == generation, acceptedMutation == mutation else { return }
        applyTask = nil
        guard
            let result = response.mutationStatusResult,
            result.status == .succeeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty,
            let status = result.payload,
            status.serverOperationIdentifier == mutation.serverOperationIdentifier
        else {
            markAcceptedOutcomeUnknown(
                "The broker returned no complete status for the accepted mutation.",
                mutation: mutation,
                generation: generation)
            return
        }
        publishAcceptedMutationStatus(status, mutation: mutation, generation: generation)
    }

    private func finishAcceptedMutationCancellation(
        _ response: DatabaseBrokerCommandResponse,
        mutation: DatabaseAcceptedMutation,
        generation: UUID
    ) {
        guard applyGeneration == generation, acceptedMutation == mutation else { return }
        applyTask = nil
        guard
            let result = response.mutationCancelResult,
            result.status == .succeeded,
            result.metadata.completeness.state == .complete,
            result.metadata.partialFailures.isEmpty,
            let cancellation = result.payload,
            cancellation.serverOperationIdentifier == mutation.serverOperationIdentifier
        else {
            let message: String
            if let result = response.mutationCancelResult {
                message = Self.message(for: result)
            } else {
                message = "The broker returned an unexpected mutation cancellation response."
            }
            safetyPhase = .accepted(message)
            mutationNotice = message
            return
        }
        if let status = cancellation.status {
            publishAcceptedMutationStatus(status, mutation: mutation, generation: generation)
            return
        }
        switch cancellation.disposition {
        case .accepted:
            safetyPhase = .accepted(
                "The database accepted the cancellation request. Completion has not been confirmed."
            )
        case .alreadyFinished:
            markAcceptedOutcomeUnknown(
                "The database reports that the mutation already finished, but its final status is unavailable.",
                mutation: mutation,
                generation: generation)
            return
        case .notFound:
            markAcceptedOutcomeUnknown(
                "The database could not find the accepted mutation. Verify database state before issuing another mutation.",
                mutation: mutation,
                generation: generation)
            return
        case .unavailable:
            safetyPhase = .accepted(
                "This database cannot cancel the accepted mutation. Continue tracking its status.")
        }
        mutationNotice = safetyPhase.message
    }

    private func publishAcceptedMutationStatus(
        _ status: DatabaseMutationStatusResult,
        mutation: DatabaseAcceptedMutation,
        generation: UUID
    ) {
        guard
            applyGeneration == generation,
            acceptedMutation == mutation,
            status.serverOperationIdentifier == mutation.serverOperationIdentifier
        else { return }
        switch status.state {
        case .accepted:
            safetyPhase = .accepted(
                "The database accepted the mutation. Completion has not been confirmed.")
        case .running:
            safetyPhase = .accepted("The accepted mutation is running.")
        case .cancelling:
            safetyPhase = .accepted("The accepted mutation is cancelling.")
        case .completed:
            guard
                let outcome = status.outcome,
                outcome.disposition == .completed
            else {
                markAcceptedOutcomeUnknown(
                    "The database reports completion without a complete mutation outcome.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            acceptedMutation = nil
            safetyPhase = .succeeded(Self.completionMessage(outcome.affectedRecords))
        case .failed:
            acceptedMutation = nil
            safetyPhase = .failed(status.error?.message ?? "The accepted mutation failed.")
        case .cancelled:
            acceptedMutation = nil
            safetyPhase = .failed("The accepted mutation was cancelled.")
        }
        mutationNotice = safetyPhase.message
    }

    private func markAcceptedOutcomeUnknown(
        _ message: String,
        mutation: DatabaseAcceptedMutation,
        generation: UUID
    ) {
        guard applyGeneration == generation, acceptedMutation == mutation else { return }
        applyTask = nil
        safetyPhase = .outcomeUnknown(message)
        mutationNotice = message
    }

    private func markOutcomeUnknown(
        _ message: String,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        applyTask = nil
        unresolvedOperationID = operationID
        safetyPhase = .outcomeUnknown(message)
        mutationNotice = message
    }

    private func invalidatePreview() {
        previewGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
    }

    private func invalidateApply() {
        applyGeneration = UUID()
        applyTask?.cancel()
        applyTask = nil
    }

    private static func message<Payload>(for result: DatabaseCommandResult<Payload>) -> String {
        if result.status == .partiallySucceeded || !result.metadata.partialFailures.isEmpty {
            return "The broker returned a partial result. No mutation was replayed."
        }
        return result.error?.message ?? "The database operation failed."
    }

    private static func message(for error: Error) -> String {
        if let clientError = error as? DatabaseBrokerCommandClientError {
            switch clientError {
            case .invalidRequest:
                return "The broker rejected the database request."
            case .timedOut:
                return "The local database broker request timed out."
            case .unavailable:
                return "The local database broker is unavailable."
            case .unsafePeer:
                return "The local database broker failed peer authentication."
            case .outcomeUnknown:
                return "The database operation outcome is unknown."
            }
        }
        return "The local database broker could not complete the operation."
    }

    private static func completionMessage(_ count: DatabaseCountMetadata) -> String {
        guard let value = count.value else { return "The database mutation completed." }
        return "The database mutation completed and affected \(value.formatted()) records."
    }

    private static func acceptedMessage(_ serverOperationIdentifier: String?) -> String {
        guard let serverOperationIdentifier, !serverOperationIdentifier.isEmpty else {
            return "The database accepted the mutation. Completion has not been confirmed."
        }
        return
            "The database accepted mutation \(serverOperationIdentifier). Completion has not been confirmed."
    }
}
