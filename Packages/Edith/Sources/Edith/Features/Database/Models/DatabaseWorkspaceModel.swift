import EdithDatabase
import Foundation
import Observation

struct DatabaseSafetyReviewSession: Identifiable, Equatable {
    let id: UUID
    let preview: DatabaseDestructivePreview
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
    private var acceptedMutationConnectionID: DatabaseConnectionID?
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
        acceptedMutationConnectionID = nil
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
        acceptedMutationConnectionID = nil
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
        if case .partiallyApplied = safetyPhase {
            acknowledgePartiallyAppliedMutation()
            return
        }
        invalidatePreview()
        let preservesUnresolvedOperation = safetyPhase.preservesUnresolvedOperation
        if !preservesUnresolvedOperation {
            invalidateApply()
            mutationRequest = nil
            applyOperationID = nil
            unresolvedOperationID = nil
            acceptedMutation = nil
            acceptedMutationConnectionID = nil
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

    func acknowledgePartiallyAppliedMutation() {
        guard case .partiallyApplied = safetyPhase else { return }
        invalidatePreview()
        invalidateApply()
        mutationRequest = nil
        applyOperationID = nil
        unresolvedOperationID = nil
        acceptedMutation = nil
        acceptedMutationConnectionID = nil
        safetyReview = nil
        reviewSessionID = nil
        previewOperationID = nil
        safetyPhase = .ready
        mutationNotice =
            "The partially applied mutation was acknowledged. Verify database state before continuing."
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
            safetyPhase = .failed("The database service returned an unexpected preview response.")
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
                "The database service returned an unexpected apply response. The mutation was not replayed.",
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
                "The database service returned a partial mutation result. Verify its durable outcome before issuing another mutation.",
                generation: generation,
                operationID: operationID)
            return
        }
        guard
            result.status == .succeeded,
            let payload = result.payload
        else {
            markOutcomeUnknown(
                "The database service did not return a proven mutation effect. Verify its durable outcome before issuing another mutation.",
                generation: generation,
                operationID: operationID)
            return
        }
        guard let connectionID = mutationRequest?.target.connectionID else {
            markOutcomeUnknown(
                "The mutation result no longer matches a tracked database connection. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
            return
        }
        publishMutationOutcome(
            payload,
            connectionID: connectionID,
            generation: generation,
            operationID: operationID)
    }

    private func failApply(
        _ message: String,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        applyTask = nil
        clearMutationTracking()
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
                "The database service has no durable record for the mutation outcome. The apply request was not replayed.",
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
                "The database service reports that the mutation is still active. Check status again before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .succeeded:
            markOutcomeUnknown(
                "The database service reports that the apply command finished, but its mutation result is unavailable. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .partiallySucceeded:
            markOutcomeUnknown(
                "The mutation partially succeeded. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .failed:
            markOutcomeUnknown(
                "The apply command failed without a proven mutation effect. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        case .cancelled:
            markOutcomeUnknown(
                "The apply command was cancelled without a proven mutation effect. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        }
    }

    private func publishReconciledOutcome(
        _ outcome: DatabaseMutationApplyResult,
        generation: UUID,
        operationID: DatabaseOperationID
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        guard let connectionID = mutationRequest?.target.connectionID else {
            markOutcomeUnknown(
                "The recovered mutation outcome no longer matches a tracked database connection.",
                generation: generation,
                operationID: operationID)
            return
        }
        publishMutationOutcome(
            outcome,
            connectionID: connectionID,
            generation: generation,
            operationID: operationID)
    }

    private func publishMutationOutcome(
        _ outcome: DatabaseMutationApplyResult,
        connectionID: DatabaseConnectionID,
        generation: UUID,
        operationID: DatabaseOperationID,
        expectedAcceptedMutation: DatabaseAcceptedMutation? = nil
    ) {
        guard applyGeneration == generation, applyOperationID == operationID else { return }
        guard Self.isValidMutationOutcome(outcome) else {
            if let expectedAcceptedMutation {
                markAcceptedOutcomeUnknown(
                    "The database returned an invalid terminal mutation effect.",
                    mutation: expectedAcceptedMutation,
                    generation: generation)
            } else {
                markOutcomeUnknown(
                    "The database returned an invalid mutation effect.",
                    generation: generation,
                    operationID: operationID)
            }
            return
        }
        if let expectedAcceptedMutation {
            guard outcome.acceptedMutation == expectedAcceptedMutation else {
                markAcceptedOutcomeUnknown(
                    "The terminal mutation outcome does not match the accepted mutation.",
                    mutation: expectedAcceptedMutation,
                    generation: generation)
                return
            }
        } else if let acceptedMutation = outcome.acceptedMutation {
            guard acceptedMutation.operationID == operationID else {
                markOutcomeUnknown(
                    "The mutation outcome does not match the originating apply operation.",
                    generation: generation,
                    operationID: operationID)
                return
            }
        }

        switch outcome.disposition {
        case .accepted:
            guard
                expectedAcceptedMutation == nil,
                outcome.effect == .unknown,
                let acceptedMutation = outcome.acceptedMutation,
                acceptedMutation.operationID == operationID,
                !acceptedMutation.serverOperationIdentifier.isEmpty
            else {
                markOutcomeUnknown(
                    "The database accepted the mutation without valid originating operation correlation.",
                    generation: generation,
                    operationID: operationID)
                return
            }
            trackAcceptedMutation(acceptedMutation, connectionID: connectionID)
            safetyPhase = .accepted(
                Self.acceptedMessage(acceptedMutation.serverOperationIdentifier))
        case .completed:
            switch outcome.effect {
            case .applied:
                clearMutationTracking()
                safetyPhase = .succeeded(Self.completionMessage(outcome.affectedRecords))
            case .notApplied:
                clearMutationTracking()
                safetyPhase = .failed(
                    outcome.error?.message ?? "The database mutation did not apply any changes.")
            case .partiallyApplied:
                retainMutationTracking(
                    operationID: operationID,
                    acceptedMutation: outcome.acceptedMutation ?? expectedAcceptedMutation,
                    connectionID: connectionID)
                safetyPhase = .partiallyApplied(Self.partialApplicationMessage(outcome))
            case .unknown:
                retainMutationTracking(
                    operationID: operationID,
                    acceptedMutation: outcome.acceptedMutation ?? expectedAcceptedMutation,
                    connectionID: connectionID)
                safetyPhase = .outcomeUnknown(
                    outcome.error?.message
                        ?? "The mutation effect is unknown. Verify database state before issuing another mutation."
                )
            }
        }
        mutationNotice = safetyPhase.message
    }

    private func trackAcceptedMutation(
        _ mutation: DatabaseAcceptedMutation,
        connectionID: DatabaseConnectionID
    ) {
        unresolvedOperationID = nil
        acceptedMutation = mutation
        acceptedMutationConnectionID = connectionID
    }

    private func retainMutationTracking(
        operationID: DatabaseOperationID,
        acceptedMutation: DatabaseAcceptedMutation?,
        connectionID: DatabaseConnectionID
    ) {
        applyOperationID = operationID
        if let acceptedMutation {
            trackAcceptedMutation(acceptedMutation, connectionID: connectionID)
        } else {
            unresolvedOperationID = operationID
            self.acceptedMutation = nil
            acceptedMutationConnectionID = nil
        }
    }

    private func clearMutationTracking() {
        applyOperationID = nil
        unresolvedOperationID = nil
        acceptedMutation = nil
        acceptedMutationConnectionID = nil
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
                "The database service could not confirm an active operation to cancel. Verify database state before issuing another mutation.",
                generation: generation,
                operationID: operationID)
        }
    }

    private func reconcileAcceptedMutation(
        _ mutation: DatabaseAcceptedMutation
    ) async {
        guard let connectionID = acceptedMutationConnectionID else {
            safetyPhase = .outcomeUnknown(
                "The accepted mutation no longer matches a tracked database connection.")
            mutationNotice = safetyPhase.message
            return
        }
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
                            connectionID: connectionID,
                            acceptedMutation: mutation,
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
        guard let connectionID = acceptedMutationConnectionID else {
            safetyPhase = .outcomeUnknown(
                "The accepted mutation no longer matches a tracked database connection.")
            mutationNotice = safetyPhase.message
            return
        }
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
                            connectionID: connectionID,
                            acceptedMutation: mutation,
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
            status.acceptedMutation == mutation
        else {
            markAcceptedOutcomeUnknown(
                "The database service returned no complete status for the accepted mutation.",
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
            cancellation.acceptedMutation == mutation
        else {
            markAcceptedOutcomeUnknown(
                "The database service returned no complete cancellation status for the accepted mutation.",
                mutation: mutation,
                generation: generation)
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
            status.acceptedMutation == mutation,
            let connectionID = acceptedMutationConnectionID
        else { return }
        switch status.state {
        case .accepted:
            guard status.outcome == nil, status.error == nil else {
                markAcceptedOutcomeUnknown(
                    "The database returned an invalid accepted mutation status.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            safetyPhase = .accepted(
                "The database accepted the mutation. Completion has not been confirmed.")
        case .running:
            guard status.outcome == nil, status.error == nil else {
                markAcceptedOutcomeUnknown(
                    "The database returned an invalid running mutation status.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            safetyPhase = .accepted("The accepted mutation is running.")
        case .cancelling:
            guard status.outcome == nil, status.error == nil else {
                markAcceptedOutcomeUnknown(
                    "The database returned an invalid cancelling mutation status.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            safetyPhase = .accepted("The accepted mutation is cancelling.")
        case .completed:
            guard
                let outcome = status.outcome,
                outcome.disposition == .completed,
                outcome.acceptedMutation == mutation,
                outcome.effect == .applied || outcome.effect == .partiallyApplied,
                status.error == outcome.error
            else {
                markAcceptedOutcomeUnknown(
                    "The database reports completion without a valid mutation effect.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            publishMutationOutcome(
                outcome,
                connectionID: connectionID,
                generation: generation,
                operationID: mutation.operationID,
                expectedAcceptedMutation: mutation)
        case .failed:
            guard
                let outcome = status.outcome,
                outcome.disposition == .completed,
                outcome.acceptedMutation == mutation,
                outcome.effect != .applied,
                let error = status.error,
                error == outcome.error
            else {
                markAcceptedOutcomeUnknown(
                    "The database reports failure without a valid mutation effect.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            publishMutationOutcome(
                outcome,
                connectionID: connectionID,
                generation: generation,
                operationID: mutation.operationID,
                expectedAcceptedMutation: mutation)
        case .cancelled:
            guard
                let outcome = status.outcome,
                outcome.disposition == .completed,
                outcome.acceptedMutation == mutation,
                outcome.effect != .applied,
                status.error == outcome.error
            else {
                markAcceptedOutcomeUnknown(
                    "The database reports cancellation without a valid mutation effect.",
                    mutation: mutation,
                    generation: generation)
                return
            }
            publishMutationOutcome(
                outcome,
                connectionID: connectionID,
                generation: generation,
                operationID: mutation.operationID,
                expectedAcceptedMutation: mutation)
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
            return "The database service returned a partial result. No mutation was replayed."
        }
        return result.error?.message ?? "The database operation failed."
    }

    private static func message(for error: Error) -> String {
        if let clientError = error as? DatabaseBrokerCommandClientError {
            switch clientError {
            case .invalidRequest:
                return "The database service rejected the database request."
            case .timedOut:
                return "The local database service request timed out."
            case .unavailable:
                return "The local database service is unavailable."
            case .unsafePeer:
                return "The local database service could not be verified."
            case .outcomeUnknown:
                return "The database operation outcome is unknown."
            }
        }
        return "The local database service could not complete the operation."
    }

    private static func completionMessage(_ count: DatabaseCountMetadata) -> String {
        guard let value = count.value else { return "The database mutation completed." }
        return "The database mutation completed and affected \(value.formatted()) records."
    }

    private static func partialApplicationMessage(_ outcome: DatabaseMutationApplyResult) -> String
    {
        if let error = outcome.error {
            return
                "The database mutation partially applied. \(error.message) Acknowledge this result only after reviewing database state."
        }
        if let value = outcome.affectedRecords.value {
            return
                "The database mutation partially applied and affected \(value.formatted()) records. Acknowledge this result only after reviewing database state."
        }
        return
            "The database mutation partially applied. Acknowledge this result only after reviewing database state."
    }

    private static func isValidMutationOutcome(_ outcome: DatabaseMutationApplyResult) -> Bool {
        switch outcome.disposition {
        case .accepted:
            return outcome.effect == .unknown
                && outcome.returnedRecords == nil
                && outcome.partialFailures.isEmpty
                && outcome.error == nil
        case .completed:
            switch outcome.effect {
            case .applied:
                return outcome.partialFailures.isEmpty && outcome.error == nil
            case .notApplied:
                return outcome.returnedRecords == nil && outcome.partialFailures.isEmpty
            case .partiallyApplied:
                return !outcome.partialFailures.isEmpty
            case .unknown:
                return outcome.returnedRecords == nil
            }
        }
    }

    private static func acceptedMessage(_ serverOperationIdentifier: String?) -> String {
        guard let serverOperationIdentifier, !serverOperationIdentifier.isEmpty else {
            return "The database accepted the mutation. Completion has not been confirmed."
        }
        return
            "The database accepted mutation \(serverOperationIdentifier). Completion has not been confirmed."
    }
}
