import EdithDatabase
import Foundation
import Testing

@Suite struct DatabaseErrorEnvelopeTests {
    @Test func structuredErrorRoundTripsWithTargetAndRetryGuidance() throws {
        let error = DatabaseErrorEnvelope(
            category: .conflict,
            message: "The record changed after it was loaded.",
            productCode: "40001",
            target: DatabaseOperationFixtures.target,
            retry: DatabaseRetryGuidance(
                action: .userDecision,
                message: "Reload the record before applying changes."),
            partialResult: DatabaseResultCompleteness(
                state: .partial,
                reason: "Earlier records remain available."),
            details: [
                DatabaseErrorDetail(name: "constraint", value: "invoices_pkey"),
                DatabaseErrorDetail(name: "safeStatementPosition", value: "18"),
            ])

        let decoded = try modelRoundTrip(error)

        #expect(decoded == error)
        #expect(decoded.category == .conflict)
        #expect(decoded.target == DatabaseOperationFixtures.target)
        #expect(decoded.retry.action == .userDecision)
    }

    @Test func partialFailureRetainsItemContext() throws {
        let error = DatabaseErrorEnvelope(
            category: .permissionDenied,
            message: "The account cannot update this record.")
        let failure = DatabasePartialFailure(
            itemIndex: 17,
            itemIdentifier: "invoice-42",
            target: DatabaseOperationFixtures.target,
            error: error)

        #expect(try modelRoundTrip(failure) == failure)
    }
}

@Suite struct DatabaseOperationContractTests {
    @Test func operationSummaryRoundTripsAllTerminalMetadata() throws {
        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "One record could not be updated.")
        let failure = DatabasePartialFailure(
            itemIndex: 2,
            itemIdentifier: "invoice-42",
            target: DatabaseOperationFixtures.target,
            error: error)
        let warning = DatabaseWarning(
            code: "partial-write",
            message: "Successful records were committed.",
            severity: .caution)
        let summary = DatabaseOperationRecordSummary(
            id: DatabaseOperationFixtures.operationID,
            kind: "data.bulk-update",
            state: .partiallySucceeded,
            connection: DatabaseConnectionFixtures.connectionIdentity,
            target: DatabaseOperationFixtures.target,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_005),
            deadline: Date(timeIntervalSince1970: 1_700_000_060),
            progress: .determinate(completed: 999, total: 1_000, unit: .records),
            cancellationSupport: .serverSide,
            retryClassification: .userDecision,
            pageCount: 10,
            recordCount: 999,
            byteCount: 65_536,
            warnings: [warning],
            partialFailures: [failure],
            error: error)

        let decoded = try modelRoundTrip(summary)

        #expect(decoded == summary)
        #expect(decoded.progress?.completed == 999)
        #expect(decoded.partialFailures.count == 1)
        #expect(decoded.cancellationSupport == .serverSide)
    }
}

@Suite struct DatabaseCommandResultTests {
    private let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete),
        count: DatabaseCountMetadata(value: 1, accuracy: .exact))

    @Test func successRoundTripsGenericPayload() throws {
        let result = DatabaseCommandResult.success(
            DatabaseRecord(fields: [DatabaseObjectField(name: "ok", value: .boolean(true))]),
            metadata: completeMetadata)

        let decoded = try modelRoundTrip(result)

        #expect(decoded == result)
        #expect(decoded.status == .succeeded)
        #expect(decoded.payload?.fields.first?.value == .boolean(true))
        #expect(decoded.error == nil)
    }

    @Test func partialResultCarriesPayloadFailuresAndWarning() throws {
        let error = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: "One item failed.")
        let failure = DatabasePartialFailure(itemIndex: 1, error: error)
        let metadata = DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .partial),
            count: DatabaseCountMetadata(value: 2, accuracy: .exact),
            warnings: [
                DatabaseWarning(
                    code: "partial",
                    message: "Inspect item failures.",
                    severity: .caution)
            ],
            partialFailures: [failure])
        let result = DatabaseCommandResult.partial(
            [DatabaseValue.string("first")],
            error: error,
            metadata: metadata)

        let decoded = try modelRoundTrip(result)

        #expect(decoded == result)
        #expect(decoded.status == .partiallySucceeded)
        #expect(decoded.metadata.partialFailures == [failure])
    }

    @Test func failureRoundTripsWithoutPayload() throws {
        let error = DatabaseErrorEnvelope(
            category: .authenticationFailed,
            message: "Authentication failed.",
            retry: DatabaseRetryGuidance(action: .reauthenticate))
        let result: DatabaseCommandResult<DatabaseEmptyPayload> = .failure(
            error,
            metadata: DatabaseResultMetadata(
                completeness: DatabaseResultCompleteness(state: .complete)))

        let decoded = try modelRoundTrip(result)

        #expect(decoded == result)
        #expect(decoded.payload == nil)
        #expect(decoded.error == error)
    }

    @Test func decodingRejectsAnInvalidFailureEnvelope() throws {
        let metadataData = try JSONEncoder().encode(completeMetadata)
        let metadata = try JSONSerialization.jsonObject(with: metadataData)
        let data = try JSONSerialization.data(
            withJSONObject: ["status": "failed", "metadata": metadata])

        #expect(throws: DatabaseCommandResultError.missingError) {
            try JSONDecoder().decode(
                DatabaseCommandResult<DatabaseEmptyPayload>.self,
                from: data)
        }
    }
}
