import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite struct DatabaseWorkspaceModelTests {
    @Test func completeMatchingPreviewPublishesTheSafetyReview() async throws {
        let sender = DatabaseWorkspaceSender()
        let operationID = Self.operationID(1)
        let preview = Self.preview(token: "preview-token")
        let model = Self.model(sender: sender, operationIDs: [operationID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        let requests = await sender.recordedRequests()
        let previewRequest = try #require(requests.first?.mutationPreviewRequest)
        #expect(previewRequest.mutation == Self.request)
        #expect(previewRequest.operation.operationID == operationID)

        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()

        #expect(model.safetyReview?.preview == preview)
        #expect(model.safetyPhase == .ready)
        #expect(model.mutationNotice == nil)
        #expect(!model.hasUnresolvedMutation)
    }

    @Test func wrongKindAndPartialPreviewResponsesAreRejected() async throws {
        let sender = DatabaseWorkspaceSender()
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(2), Self.operationID(3)])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(
            .operationGet(
                .success(
                    DatabaseOperationGetResult(operation: nil),
                    metadata: Self.completeMetadata)),
            at: 0)
        await model.waitForPreview()

        #expect(model.safetyReview == nil)
        #expect(
            model.safetyPhase
                == .failed("The database service returned an unexpected preview response."))

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.partialPreviewResponse(Self.preview()), at: 1)
        await model.waitForPreview()

        #expect(model.safetyReview == nil)
        #expect(
            model.safetyPhase
                == .failed(
                    "The database service returned a partial result. No mutation was replayed."))
    }

    @Test func stalePreviewCannotReplaceTheNewestRefresh() async throws {
        let sender = DatabaseWorkspaceSender()
        let oldPreview = Self.preview(token: "old-token")
        let freshPreview = Self.preview(
            token: "fresh-token",
            issuedAt: Self.issuedAt.addingTimeInterval(5))
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(4), Self.operationID(5)])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        let refresh = Task { @MainActor in
            await model.refreshSafetyPreview()
        }
        await sender.waitUntilRequested(2)

        await sender.succeed(Self.previewResponse(freshPreview), at: 1)
        await refresh.value
        #expect(model.safetyReview?.preview.token.rawValue == "fresh-token")

        await sender.succeed(Self.previewResponse(oldPreview), at: 0)
        await sender.waitUntilFinished(2)
        await Self.yieldMainActor()

        #expect(model.safetyReview?.preview == freshPreview)
        #expect(model.safetyPhase == .ready)
        let requests = await sender.recordedRequests()
        #expect(requests.compactMap(\.mutationPreviewRequest).count == 2)
        #expect(
            requests.compactMap(\.mutationPreviewRequest).allSatisfy {
                $0.mutation == Self.request
            })
    }

    @Test func applyUsesTheModelsTokenAndImmutableRequest() async throws {
        let sender = DatabaseWorkspaceSender()
        let previewID = Self.operationID(6)
        let applyID = Self.operationID(7)
        let preview = Self.preview(token: "authority-token")
        var submittedRequest = Self.request
        let expectedRequest = submittedRequest
        let model = Self.model(
            sender: sender,
            operationIDs: [previewID, applyID])

        model.requestSafetyReview(for: submittedRequest)
        submittedRequest = Self.otherRequest
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()

        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        let requests = await sender.recordedRequests()
        let applyRequest = try #require(requests[1].mutationApplyRequest)
        #expect(applyRequest.mutation == expectedRequest)
        #expect(applyRequest.mutation != submittedRequest)
        #expect(applyRequest.token == preview.token)
        #expect(applyRequest.confirmationText == preview.requiredConfirmation.text)
        #expect(applyRequest.operation.operationID == applyID)

        await sender.succeed(Self.completedApplyResponse(), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isSucceeded }

        #expect(model.safetyPhase.isSucceeded)
        #expect(!model.hasUnresolvedMutation)
    }

    @Test func unknownApplyIsNeverReplayedAndUsesTheDurableOutcomeRecord() async throws {
        let sender = DatabaseWorkspaceSender()
        let previewID = Self.operationID(8)
        let applyID = Self.operationID(9)
        let preview = Self.preview(token: "unknown-token")
        let model = Self.model(
            sender: sender,
            operationIDs: [previewID, applyID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()

        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.fail(.outcomeUnknown, at: 1)
        await sender.waitUntilRequested(3)
        let requests = await sender.recordedRequests()
        let reconciliation = try #require(requests[2].mutationOutcomeGetRequest)
        #expect(reconciliation.operationID == applyID)
        #expect(requests.filter { $0.kind == .mutationApply }.count == 1)
        #expect(requests.filter { $0.kind == .mutationOutcomeGet }.count == 1)

        await sender.succeed(Self.operationResponse(id: applyID, state: .running), at: 2)
        await sender.waitUntilFinished(3)
        await Self.waitUntil { model.safetyPhase.isOutcomeUnknown }

        #expect(model.safetyPhase.isOutcomeUnknown)
        #expect(model.unresolvedOperationID == applyID)
        #expect(model.hasUnresolvedMutation)
        let finalRequests = await sender.recordedRequests()
        #expect(finalRequests.filter { $0.kind == .mutationApply }.count == 1)
    }

    @Test func postEffectUnknownResultRemainsTracked() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "post-effect-unknown-token")
        let applyID = Self.operationID(41)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(40), applyID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(
            .mutationApply(
                .success(
                    Self.completedApplyResult(
                        effect: .unknown,
                        error: DatabaseErrorEnvelope(
                            category: .internalFailure,
                            message: "The adapter stopped after execution began.")),
                    metadata: Self.completeMetadata)),
            at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isOutcomeUnknown }

        #expect(model.unresolvedOperationID == applyID)
        #expect(model.acceptedMutation == nil)
        #expect(model.hasTrackedMutation)
        #expect(model.mutationNotice == "The adapter stopped after execution began.")
    }

    @Test func cancellingAnActiveApplyWithoutAnEffectRemainsTracked() async throws {
        let sender = DatabaseWorkspaceSender()
        let previewID = Self.operationID(10)
        let applyID = Self.operationID(11)
        let preview = Self.preview(token: "cancel-token")
        let model = Self.model(
            sender: sender,
            operationIDs: [previewID, applyID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()

        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        #expect(model.safetyPhase == .executing)
        model.cancelSafetyOperation()
        #expect(model.safetyPhase == .cancelling)
        await sender.waitUntilRequested(3)

        let cancellationRequests = await sender.recordedRequests()
        let applyRequest = try #require(cancellationRequests[1].mutationApplyRequest)
        let cancelRequest = try #require(cancellationRequests[2].operationCancelRequest)
        #expect(applyRequest.operation.operationID == applyID)
        #expect(cancelRequest.operationID == applyID)
        #expect(cancellationRequests.filter { $0.kind == .mutationApply }.count == 1)
        #expect(cancellationRequests.filter { $0.kind == .operationCancel }.count == 1)

        await sender.succeed(Self.acceptedCancellationResponse(id: applyID), at: 2)
        await sender.waitUntilRequested(4)
        let reconciliationRequests = await sender.recordedRequests()
        #expect(reconciliationRequests[3].mutationOutcomeGetRequest?.operationID == applyID)
        await sender.succeed(Self.operationResponse(id: applyID, state: .cancelled), at: 3)
        await sender.succeed(Self.completedApplyResponse(), at: 1)
        await sender.waitUntilFinished(4)
        await Self.waitUntil { model.safetyPhase.isOutcomeUnknown }

        #expect(model.safetyPhase.isOutcomeUnknown)
        #expect(model.unresolvedOperationID == applyID)
        #expect(model.hasUnresolvedMutation)
        let finalRequests = await sender.recordedRequests()
        #expect(finalRequests.filter { $0.kind == .mutationApply }.count == 1)
    }

    @Test func acceptedApplyIsNotPresentedAsCompleted() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "accepted-token")
        let applyID = Self.operationID(13)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(12), applyID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        #expect(model.safetyPhase.isAccepted)
        #expect(!model.safetyPhase.isSucceeded)
        #expect(model.hasTrackedMutation)
        #expect(model.acceptedMutation?.operationID == applyID)
        #expect(model.acceptedMutation?.serverOperationIdentifier == "server-job-42")
        #expect(
            model.mutationNotice
                == "The database accepted mutation server-job-42. Completion has not been confirmed."
        )
    }

    @Test func acceptedMutationStatusRemainsTrackedUntilACompleteOutcomeArrives() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "status-token")
        let applyID = Self.operationID(16)
        let acceptedMutation = Self.acceptedMutation(operationID: applyID)
        let firstStatusID = Self.operationID(17)
        let secondStatusID = Self.operationID(18)
        let model = Self.model(
            sender: sender,
            operationIDs: [
                Self.operationID(15), applyID, firstStatusID, secondStatusID,
            ])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        let runningStatus = Task { @MainActor in
            await model.reconcileSafetyOperation()
        }
        await sender.waitUntilRequested(3)
        var requests = await sender.recordedRequests()
        let firstStatusRequest = try #require(requests[2].mutationStatusRequest)
        #expect(firstStatusRequest.connectionID == Self.connectionID)
        #expect(firstStatusRequest.acceptedMutation == acceptedMutation)
        #expect(firstStatusRequest.operation.operationID == firstStatusID)
        #expect(firstStatusRequest.operation.operationID != applyID)
        await sender.succeed(
            Self.mutationStatusResponse(
                acceptedMutation: acceptedMutation,
                state: .running),
            at: 2)
        await runningStatus.value

        #expect(model.safetyPhase == .accepted("The accepted mutation is running."))
        #expect(model.hasTrackedMutation)
        #expect(model.acceptedMutation?.serverOperationIdentifier == "server-job-42")

        let completedStatus = Task { @MainActor in
            await model.reconcileSafetyOperation()
        }
        await sender.waitUntilRequested(4)
        requests = await sender.recordedRequests()
        let secondStatusRequest = try #require(requests[3].mutationStatusRequest)
        #expect(secondStatusRequest.operation.operationID == secondStatusID)
        await sender.succeed(
            Self.mutationStatusResponse(
                acceptedMutation: acceptedMutation,
                state: .completed,
                outcome: Self.completedApplyResult(acceptedMutation: acceptedMutation)),
            at: 3)
        await completedStatus.value

        #expect(model.safetyPhase.isSucceeded)
        #expect(model.acceptedMutation == nil)
        #expect(!model.hasTrackedMutation)
        #expect(requests.filter { $0.kind == .mutationApply }.count == 1)
        #expect(requests.filter { $0.kind == .mutationStatus }.count == 2)
    }

    @Test func failedAcceptedMutationWithNotAppliedEffectClearsTracking() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "failed-not-applied-token")
        let applyID = Self.operationID(43)
        let acceptedMutation = Self.acceptedMutation(operationID: applyID)
        let statusID = Self.operationID(44)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(42), applyID, statusID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        let error = DatabaseErrorEnvelope(
            category: .conflict,
            message: "The database rejected the mutation before applying changes.")
        let reconciliation = Task { @MainActor in
            await model.reconcileSafetyOperation()
        }
        await sender.waitUntilRequested(3)
        await sender.succeed(
            Self.mutationStatusResponse(
                acceptedMutation: acceptedMutation,
                state: .failed,
                outcome: Self.completedApplyResult(
                    effect: .notApplied,
                    acceptedMutation: acceptedMutation,
                    error: error),
                error: error),
            at: 2)
        await reconciliation.value

        #expect(model.safetyPhase == .failed(error.message))
        #expect(model.acceptedMutation == nil)
        #expect(model.unresolvedOperationID == nil)
        #expect(!model.hasTrackedMutation)
    }

    @Test func terminalPartialEffectBlocksUntilExplicitAcknowledgement() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "terminal-partial-token")
        let applyID = Self.operationID(46)
        let acceptedMutation = Self.acceptedMutation(operationID: applyID)
        let model = Self.model(
            sender: sender,
            operationIDs: [
                Self.operationID(45), applyID, Self.operationID(47), Self.operationID(48),
            ])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "Some records could not be changed.")
        let partialFailure = DatabasePartialFailure(itemIndex: 4, error: error)
        let reconciliation = Task { @MainActor in
            await model.reconcileSafetyOperation()
        }
        await sender.waitUntilRequested(3)
        await sender.succeed(
            Self.mutationStatusResponse(
                acceptedMutation: acceptedMutation,
                state: .completed,
                outcome: Self.completedApplyResult(
                    effect: .partiallyApplied,
                    acceptedMutation: acceptedMutation,
                    partialFailures: [partialFailure],
                    error: error),
                error: error),
            at: 2)
        await reconciliation.value
        await Self.waitUntil { model.safetyPhase.isPartiallyApplied }

        #expect(model.hasTrackedMutation)
        #expect(model.acceptedMutation == acceptedMutation)
        model.requestSafetyReview(for: Self.otherRequest)
        await Self.yieldMainActor()
        var requests = await sender.recordedRequests()
        #expect(requests.count == 3)
        #expect(
            model.mutationNotice
                == "Resolve the active or uncertain mutation before starting another mutation.")

        model.acknowledgePartiallyAppliedMutation()
        #expect(!model.hasTrackedMutation)
        #expect(model.safetyPhase == .ready)
        model.requestSafetyReview(for: Self.otherRequest)
        await sender.waitUntilRequested(4)
        requests = await sender.recordedRequests()
        #expect(requests[3].mutationPreviewRequest?.mutation == Self.otherRequest)
        await sender.succeed(Self.previewResponse(Self.preview(token: "next-token")), at: 3)
        await model.waitForPreview()
    }

    @Test func acceptedMutationCancellationWithoutAnEffectRemainsTracked() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "accepted-cancel-token")
        let applyID = Self.operationID(20)
        let acceptedMutation = Self.acceptedMutation(operationID: applyID)
        let cancelID = Self.operationID(21)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(19), applyID, cancelID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        model.cancelSafetyOperation()
        await sender.waitUntilRequested(3)
        let requests = await sender.recordedRequests()
        let cancellation = try #require(requests[2].mutationCancelRequest)
        #expect(cancellation.connectionID == Self.connectionID)
        #expect(cancellation.acceptedMutation == acceptedMutation)
        #expect(cancellation.operation.operationID == cancelID)
        #expect(cancellation.operation.operationID != applyID)
        #expect(requests.filter { $0.kind == .operationCancel }.isEmpty)
        await sender.succeed(
            Self.acceptedMutationCancellationResponse(
                acceptedMutation: acceptedMutation,
                state: .cancelled),
            at: 2)
        await sender.waitUntilFinished(3)
        await Self.waitUntil {
            model.safetyPhase.isOutcomeUnknown
        }

        #expect(model.safetyPhase.isOutcomeUnknown)
        #expect(model.acceptedMutation == acceptedMutation)
        #expect(model.hasTrackedMutation)
    }

    @Test func cancelledAcceptedMutationWithNotAppliedEffectClearsTracking() async throws {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "accepted-cancel-not-applied-token")
        let applyID = Self.operationID(50)
        let acceptedMutation = Self.acceptedMutation(operationID: applyID)
        let cancelID = Self.operationID(51)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(49), applyID, cancelID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        model.cancelSafetyOperation()
        await sender.waitUntilRequested(3)
        await sender.succeed(
            Self.acceptedMutationCancellationResponse(
                acceptedMutation: acceptedMutation,
                state: .cancelled,
                outcome: Self.completedApplyResult(
                    effect: .notApplied,
                    acceptedMutation: acceptedMutation)),
            at: 2)
        await sender.waitUntilFinished(3)
        await Self.waitUntil { !model.hasTrackedMutation }

        #expect(
            model.safetyPhase
                == .failed("The database mutation did not apply any changes."))
        #expect(model.acceptedMutation == nil)
        #expect(model.unresolvedOperationID == nil)
    }

    @Test func malformedAndPartialApplyResultsRemainTrackedAsUncertain() async throws {
        let wrongKindSender = DatabaseWorkspaceSender()
        let wrongKindPreview = Self.preview(token: "wrong-kind-apply-token")
        let wrongKindApplyID = Self.operationID(23)
        let wrongKindModel = Self.model(
            sender: wrongKindSender,
            operationIDs: [Self.operationID(22), wrongKindApplyID])

        wrongKindModel.requestSafetyReview(for: Self.request)
        await wrongKindSender.waitUntilRequested(1)
        await wrongKindSender.succeed(Self.previewResponse(wrongKindPreview), at: 0)
        await wrongKindModel.waitForPreview()
        wrongKindModel.confirmSafetyReview(wrongKindPreview.requiredConfirmation.text)
        await wrongKindSender.waitUntilRequested(2)
        await wrongKindSender.succeed(
            .operationGet(
                .success(
                    DatabaseOperationGetResult(operation: nil),
                    metadata: Self.completeMetadata)),
            at: 1)
        await wrongKindSender.waitUntilFinished(2)
        await Self.waitUntil { wrongKindModel.safetyPhase.isOutcomeUnknown }

        #expect(
            wrongKindModel.safetyPhase
                == .outcomeUnknown(
                    "The database service returned an unexpected apply response. The mutation was not replayed."
                ))
        #expect(wrongKindModel.unresolvedOperationID == wrongKindApplyID)
        #expect(wrongKindModel.hasTrackedMutation)

        let partialSender = DatabaseWorkspaceSender()
        let partialPreview = Self.preview(token: "partial-apply-token")
        let partialApplyID = Self.operationID(25)
        let partialModel = Self.model(
            sender: partialSender,
            operationIDs: [Self.operationID(24), partialApplyID])

        partialModel.requestSafetyReview(for: Self.request)
        await partialSender.waitUntilRequested(1)
        await partialSender.succeed(Self.previewResponse(partialPreview), at: 0)
        await partialModel.waitForPreview()
        partialModel.confirmSafetyReview(partialPreview.requiredConfirmation.text)
        await partialSender.waitUntilRequested(2)
        await partialSender.succeed(Self.partialApplyResponse(), at: 1)
        await partialSender.waitUntilFinished(2)
        await Self.waitUntil { partialModel.safetyPhase.isOutcomeUnknown }

        #expect(
            partialModel.safetyPhase
                == .outcomeUnknown(
                    "The database service returned a partial mutation result. Verify its durable outcome before issuing another mutation."
                ))
        #expect(partialModel.unresolvedOperationID == partialApplyID)
        #expect(partialModel.hasTrackedMutation)
        let partialRequests = await partialSender.recordedRequests()
        #expect(partialRequests.filter { $0.kind == .mutationApply }.count == 1)
    }

    @Test func dismissalPreservesAcceptedAndUnknownMutationTracking() async {
        let acceptedSender = DatabaseWorkspaceSender()
        let acceptedPreview = Self.preview(token: "dismiss-accepted-token")
        let acceptedApplyID = Self.operationID(27)
        let acceptedModel = Self.model(
            sender: acceptedSender,
            operationIDs: [Self.operationID(26), acceptedApplyID])

        acceptedModel.requestSafetyReview(for: Self.request)
        await acceptedSender.waitUntilRequested(1)
        await acceptedSender.succeed(Self.previewResponse(acceptedPreview), at: 0)
        await acceptedModel.waitForPreview()
        acceptedModel.confirmSafetyReview(acceptedPreview.requiredConfirmation.text)
        await acceptedSender.waitUntilRequested(2)
        await acceptedSender.succeed(
            Self.acceptedApplyResponse(operationID: acceptedApplyID), at: 1)
        await acceptedSender.waitUntilFinished(2)
        await Self.waitUntil { acceptedModel.safetyPhase.isAccepted }
        acceptedModel.dismissSafetyReview()

        #expect(acceptedModel.safetyReview == nil)
        #expect(acceptedModel.safetyPhase.isAccepted)
        #expect(acceptedModel.acceptedMutation?.serverOperationIdentifier == "server-job-42")
        #expect(acceptedModel.hasTrackedMutation)

        let unknownSender = DatabaseWorkspaceSender()
        let unknownPreview = Self.preview(token: "dismiss-unknown-token")
        let unknownApplyID = Self.operationID(29)
        let unknownModel = Self.model(
            sender: unknownSender,
            operationIDs: [Self.operationID(28), unknownApplyID])

        unknownModel.requestSafetyReview(for: Self.request)
        await unknownSender.waitUntilRequested(1)
        await unknownSender.succeed(Self.previewResponse(unknownPreview), at: 0)
        await unknownModel.waitForPreview()
        unknownModel.confirmSafetyReview(unknownPreview.requiredConfirmation.text)
        await unknownSender.waitUntilRequested(2)
        await unknownSender.succeed(
            .operationGet(
                .success(
                    DatabaseOperationGetResult(operation: nil),
                    metadata: Self.completeMetadata)),
            at: 1)
        await unknownSender.waitUntilFinished(2)
        await Self.waitUntil { unknownModel.safetyPhase.isOutcomeUnknown }
        unknownModel.dismissSafetyReview()

        #expect(unknownModel.safetyReview == nil)
        #expect(unknownModel.safetyPhase.isOutcomeUnknown)
        #expect(unknownModel.unresolvedOperationID == unknownApplyID)
        #expect(unknownModel.hasTrackedMutation)
    }

    @Test func trackedMutationBlocksStartingASecondMutation() async {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "blocking-token")
        let applyID = Self.operationID(31)
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(30), applyID])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.succeed(Self.acceptedApplyResponse(operationID: applyID), at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil { model.safetyPhase.isAccepted }

        model.requestSafetyReview(for: Self.otherRequest)
        await Self.yieldMainActor()

        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.filter { $0.kind == .mutationPreview }.count == 1)
        #expect(model.acceptedMutation?.serverOperationIdentifier == "server-job-42")
        #expect(model.hasTrackedMutation)
        #expect(
            model.mutationNotice
                == "Resolve the active or uncertain mutation before starting another mutation.")
    }

    @Test func prewriteApplyTimeoutFailsWithoutLeavingUncertainTracking() async {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "prewrite-timeout-token")
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(32), Self.operationID(33)])

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await sender.waitUntilRequested(2)
        await sender.fail(.timedOut, at: 1)
        await sender.waitUntilFinished(2)
        await Self.waitUntil {
            model.safetyPhase
                == .failed("The local database service request timed out.")
        }

        #expect(
            model.safetyPhase
                == .failed("The local database service request timed out."))
        #expect(!model.hasTrackedMutation)
        let requests = await sender.recordedRequests()
        #expect(requests.filter { $0.kind == .mutationApply }.count == 1)
    }

    @Test func expiredConfirmationCannotSendAnApply() async {
        let sender = DatabaseWorkspaceSender()
        let preview = Self.preview(token: "expired-token")
        let model = Self.model(
            sender: sender,
            operationIDs: [Self.operationID(14)],
            currentDate: preview.expiresAt)

        model.requestSafetyReview(for: Self.request)
        await sender.waitUntilRequested(1)
        await sender.succeed(Self.previewResponse(preview), at: 0)
        await model.waitForPreview()
        model.confirmSafetyReview(preview.requiredConfirmation.text)
        await Self.yieldMainActor()

        #expect(
            model.safetyPhase
                == .failed("The preview expired. Create a fresh preview before retrying."))
        let requests = await sender.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.kind != .mutationApply })
    }

    private static let issuedAt = Date(timeIntervalSince1970: 2_000)
    private static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "64CA1857-85B8-49D7-9421-9BA52282084E")!)

    private static let target = DatabaseTargetIdentifier(
        connectionID: connectionID,
        object: DatabaseObjectIdentifier(
            kind: .table,
            path: ["orders", "public", "invoices"]))

    private static let request = DatabaseDestructiveRequest(
        target: target,
        predicate: .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("state"),
                operation: .equal,
                values: [.string("pending")])),
        payload: .relational(
            product: .postgresql,
            statement: "DELETE FROM invoices WHERE state = $1",
            parameters: [
                DatabaseMutationParameter(name: "state", value: .string("pending"))
            ]))

    private static let otherRequest = DatabaseDestructiveRequest(
        target: target,
        predicate: .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("state"),
                operation: .equal,
                values: [.string("paid")])),
        payload: .relational(
            product: .postgresql,
            statement: "DELETE FROM invoices WHERE state = $1",
            parameters: [
                DatabaseMutationParameter(name: "state", value: .string("paid"))
            ]))

    private static let connection = DatabaseConnectionIdentity(
        id: connectionID,
        displayName: "Primary orders",
        productHint: .postgresql,
        environment: DatabaseEnvironmentMetadata(
            kind: .production,
            label: "customer-a",
            protection: .confirmationRequired))

    private static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    private static func model(
        sender: DatabaseWorkspaceSender,
        operationIDs: [DatabaseOperationID],
        currentDate: Date? = nil
    ) -> DatabaseWorkspaceModel {
        let sequence = DatabaseOperationIDSequence(operationIDs)
        let resolvedCurrentDate = currentDate ?? issuedAt.addingTimeInterval(30)
        return DatabaseWorkspaceModel(
            sender: sender,
            makeOperationID: { sequence.next() },
            makeSessionID: {
                UUID(uuidString: "BF471404-90F0-4E37-A080-F4132E14BB6E")!
            },
            currentDate: { resolvedCurrentDate })
    }

    private static func operationID(_ value: UInt8) -> DatabaseOperationID {
        let suffix = String(format: "%012X", value)
        return DatabaseOperationID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
    }

    private static func preview(
        token: String = "preview-token",
        issuedAt: Date? = nil
    ) -> DatabaseDestructivePreview {
        let resolvedIssuedAt = issuedAt ?? Self.issuedAt
        return DatabaseDestructivePreview(
            effect: DatabaseDestructiveEffect(
                action: .deleteMany,
                connection: connection,
                context: DatabaseMutationContext(
                    kind: .database,
                    value: "orders",
                    schema: "public"),
                target: target,
                selectedRecords: [],
                predicate: request.predicate,
                scope: .predicate,
                impact: DatabaseMutationImpact(
                    count: DatabaseCountMetadata(value: 12, accuracy: .estimated),
                    description: "About 12 matching invoices"),
                transactionBehavior: .transactional,
                rollbackAvailability: .available,
                executionMode: .synchronous,
                executionDigest: "execution-digest",
                displayDigest: "display-digest"),
            request: DatabaseMutationPreview(
                product: .postgresql,
                kind: .sql,
                command: "DELETE FROM invoices WHERE state = $1",
                parameters: [
                    DatabaseMutationParameterPreview(name: "state", valueKind: .string)
                ],
                body: nil),
            warnings: [
                DatabaseWarning(
                    code: "production",
                    message: "This changes production data.",
                    severity: .high,
                    target: target)
            ],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .connectionAndTarget,
                text: "Primary orders invoices"),
            issuedAt: resolvedIssuedAt,
            expiresAt: resolvedIssuedAt.addingTimeInterval(60),
            token: DatabaseConfirmationToken(rawValue: token))
    }

    private static func previewResponse(
        _ preview: DatabaseDestructivePreview
    ) -> DatabaseBrokerCommandResponse {
        .mutationPreview(
            .success(
                DatabaseMutationPreviewResult(preview: preview),
                metadata: completeMetadata))
    }

    private static func partialPreviewResponse(
        _ preview: DatabaseDestructivePreview
    ) -> DatabaseBrokerCommandResponse {
        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "Preview was partial")
        return .mutationPreview(
            .partial(
                DatabaseMutationPreviewResult(preview: preview),
                error: error,
                metadata: DatabaseResultMetadata(
                    completeness: DatabaseResultCompleteness(state: .partial),
                    partialFailures: [
                        DatabasePartialFailure(itemIndex: 0, error: error)
                    ])))
    }

    private static func completedApplyResponse() -> DatabaseBrokerCommandResponse {
        .mutationApply(
            .success(
                completedApplyResult(),
                metadata: completeMetadata))
    }

    private static func completedApplyResult(
        effect: DatabaseMutationEffect = .applied,
        acceptedMutation: DatabaseAcceptedMutation? = nil,
        partialFailures: [DatabasePartialFailure] = [],
        error: DatabaseErrorEnvelope? = nil
    ) -> DatabaseMutationApplyResult {
        DatabaseMutationApplyResult(
            disposition: .completed,
            effect: effect,
            affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .exact),
            acceptedMutation: acceptedMutation,
            partialFailures: partialFailures,
            error: error)
    }

    private static func acceptedMutation(
        operationID: DatabaseOperationID,
        identifier: String = "server-job-42"
    ) -> DatabaseAcceptedMutation {
        DatabaseAcceptedMutation(
            operationID: operationID,
            serverOperationIdentifier: identifier)
    }

    private static func acceptedApplyResponse(
        operationID: DatabaseOperationID,
        identifier: String = "server-job-42"
    ) -> DatabaseBrokerCommandResponse {
        .mutationApply(
            .success(
                DatabaseMutationApplyResult(
                    disposition: .accepted,
                    effect: .unknown,
                    affectedRecords: DatabaseCountMetadata(value: nil, accuracy: .unknown),
                    acceptedMutation: acceptedMutation(
                        operationID: operationID,
                        identifier: identifier)),
                metadata: completeMetadata))
    }

    private static func partialApplyResponse() -> DatabaseBrokerCommandResponse {
        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "Apply was partial")
        return .mutationApply(
            .partial(
                completedApplyResult(),
                error: error,
                metadata: DatabaseResultMetadata(
                    completeness: DatabaseResultCompleteness(state: .partial),
                    partialFailures: [
                        DatabasePartialFailure(itemIndex: 0, error: error)
                    ])))
    }

    private static func mutationStatusResponse(
        acceptedMutation: DatabaseAcceptedMutation,
        state: DatabaseMutationOperationState,
        outcome: DatabaseMutationApplyResult? = nil,
        error: DatabaseErrorEnvelope? = nil
    ) -> DatabaseBrokerCommandResponse {
        .mutationStatus(
            .success(
                DatabaseMutationStatusResult(
                    acceptedMutation: acceptedMutation,
                    state: state,
                    outcome: outcome,
                    error: error),
                metadata: completeMetadata))
    }

    private static func acceptedMutationCancellationResponse(
        acceptedMutation: DatabaseAcceptedMutation,
        state: DatabaseMutationOperationState,
        outcome: DatabaseMutationApplyResult? = nil,
        error: DatabaseErrorEnvelope? = nil
    ) -> DatabaseBrokerCommandResponse {
        .mutationCancel(
            .success(
                DatabaseMutationCancelResult(
                    acceptedMutation: acceptedMutation,
                    disposition: .accepted,
                    status: DatabaseMutationStatusResult(
                        acceptedMutation: acceptedMutation,
                        state: state,
                        outcome: outcome,
                        error: error)),
                metadata: completeMetadata))
    }

    private static func acceptedCancellationResponse(
        id: DatabaseOperationID
    ) -> DatabaseBrokerCommandResponse {
        .operationCancel(
            .success(
                DatabaseOperationCancelResult(
                    operationID: id,
                    disposition: .accepted,
                    cancellationSupport: .serverSide),
                metadata: completeMetadata))
    }

    private static func operationResponse(
        id: DatabaseOperationID,
        state: DatabaseOperationState
    ) -> DatabaseBrokerCommandResponse {
        .mutationOutcomeGet(
            .success(
                DatabaseMutationOutcomeGetResult(
                    operation: DatabaseOperationRecordSummary(
                        id: id,
                        kind: .databaseMutationApply,
                        state: state,
                        connection: connection,
                        target: target,
                        cancellationSupport: .serverSide,
                        retryClassification: .never),
                    outcome: nil),
                metadata: completeMetadata))
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("The model did not reach the expected state.")
    }

    private static func yieldMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private actor DatabaseWorkspaceSender: DatabaseBrokerCommandSending {
    private enum Outcome: Sendable {
        case response(DatabaseBrokerCommandResponse)
        case failure(DatabaseBrokerCommandClientError)
    }

    private var requests: [DatabaseBrokerCommandRequest] = []
    private var finishedCount = 0
    private var outcomes: [Int: Outcome] = [:]
    private var outcomeWaiters: [Int: CheckedContinuation<Outcome, Never>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        let index = requests.count
        requests.append(request)
        resumeRequestWaiters()
        let outcome: Outcome
        if let prepared = outcomes.removeValue(forKey: index) {
            outcome = prepared
        } else {
            outcome = await withCheckedContinuation { outcomeWaiters[index] = $0 }
        }
        finishedCount += 1
        resumeFinishWaiters()
        switch outcome {
        case .response(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func succeed(_ response: DatabaseBrokerCommandResponse, at index: Int) {
        resolve(.response(response), at: index)
    }

    func fail(_ error: DatabaseBrokerCommandClientError, at index: Int) {
        resolve(.failure(error), at: index)
    }

    func waitUntilRequested(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func waitUntilFinished(_ count: Int) async {
        guard finishedCount < count else { return }
        await withCheckedContinuation { finishWaiters.append((count, $0)) }
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }

    private func resolve(_ outcome: Outcome, at index: Int) {
        if let waiter = outcomeWaiters.removeValue(forKey: index) {
            waiter.resume(returning: outcome)
        } else {
            outcomes[index] = outcome
        }
    }

    private func resumeRequestWaiters() {
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeFinishWaiters() {
        let ready = finishWaiters.filter { finishedCount >= $0.0 }
        finishWaiters.removeAll { finishedCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private final class DatabaseOperationIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var operationIDs: [DatabaseOperationID]

    init(_ operationIDs: [DatabaseOperationID]) {
        self.operationIDs = operationIDs
    }

    func next() -> DatabaseOperationID {
        lock.lock()
        defer { lock.unlock() }
        return operationIDs.removeFirst()
    }
}

private extension DatabaseSafetyReviewPhase {
    var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
