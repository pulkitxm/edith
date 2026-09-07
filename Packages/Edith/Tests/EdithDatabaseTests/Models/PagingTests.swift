import EdithDatabase
import Foundation
import Testing

@Suite struct DatabasePagingTests {
    @Test func pageSizeUsesProductBounds() throws {
        #expect(DatabasePageSize.defaultSize.value == 200)
        #expect(DatabasePageSize.maximumSize.value == 2_000)
        #expect(try DatabasePageSize(1).value == 1)
        #expect(try DatabasePageSize(2_000).value == 2_000)
        #expect(
            throws: DatabasePageSizeError.outOfBounds(
                requested: 0,
                minimum: 1,
                maximum: 2_000)
        ) {
            try DatabasePageSize(0)
        }
        #expect(
            throws: DatabasePageSizeError.outOfBounds(
                requested: 2_001,
                minimum: 1,
                maximum: 2_000)
        ) {
            try DatabasePageSize(2_001)
        }
    }

    @Test func continuationEnvelopeBindsItsPagingContext() throws {
        let context = DatabaseContinuationContext(
            connectionID: DatabaseConnectionFixtures.connectionID,
            target: DatabaseOperationFixtures.target,
            requestDigest: "sha256:request",
            sortDigest: "sha256:sort",
            projectionDigest: "sha256:projection")
        let envelope = DatabaseContinuationEnvelope(
            identifier: UUID(uuidString: "DC8EE407-2F24-47D8-B122-584D1C3B1353")!,
            context: context,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_000_300),
            payload: Data([1, 3, 3, 7]),
            signature: Data([9, 8, 7, 6]))

        let decoded = try modelRoundTrip(envelope)

        #expect(decoded == envelope)
        #expect(decoded.context.connectionID == DatabaseConnectionFixtures.connectionID)
        #expect(decoded.context.target == DatabaseOperationFixtures.target)
        #expect(decoded.context.requestDigest == "sha256:request")
    }

    @Test func requestPreservesTypedFilterProjectionAndMultiSort() throws {
        let filter = DatabaseFilter.all([
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("total"),
                    operation: .greaterThanOrEqual,
                    values: [.decimal("100.00")]
                )),
            .any([
                .predicate(
                    DatabaseFilterPredicate(
                        field: DatabaseFieldPath("status"),
                        operation: .in,
                        values: [.string("open"), .string("overdue")])),
                .not(
                    .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath(["customer", "blocked"]),
                            operation: .equal,
                            values: [.boolean(true)]))),
            ]),
        ])
        let request = DatabasePageRequest(
            pageSize: try DatabasePageSize(350),
            continuation: DatabaseContinuationToken(rawValue: "opaque-token"),
            projection: DatabaseProjection(
                mode: .include,
                fields: [
                    DatabaseProjectedField(path: DatabaseFieldPath("id")),
                    DatabaseProjectedField(path: DatabaseFieldPath("total"), alias: "amount"),
                ]),
            filter: filter,
            sorts: [
                DatabaseSort(
                    field: DatabaseFieldPath("created_at"),
                    direction: .descending,
                    nullPlacement: .last),
                DatabaseSort(field: DatabaseFieldPath("id"), direction: .ascending),
            ],
            consistency: .snapshot)

        let decoded = try modelRoundTrip(request)

        #expect(decoded == request)
        #expect(decoded.sorts.count == 2)
        #expect(decoded.pageSize.value == 350)
        #expect(decoded.continuation?.rawValue == "opaque-token")
    }

    @Test func pageCarriesCompletenessCountAndWarnings() throws {
        let warning = DatabaseWarning(
            code: "scan-in-progress",
            message: "The scan has not visited every key.",
            severity: .information,
            target: DatabaseOperationFixtures.target)
        let page = DatabasePage(
            records: [
                DatabaseRecord(
                    identity: DatabaseOperationFixtures.target.record,
                    fields: [
                        DatabaseObjectField(name: "id", value: .signedInteger(42)),
                        DatabaseObjectField(name: "amount", value: .decimal("100.00")),
                    ])
            ],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("id"),
                    displayName: "id",
                    typeName: "int8",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true)
            ],
            nextContinuation: DatabaseContinuationToken(rawValue: "next"),
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: .partial,
                    reason: "More records are available."),
                count: DatabaseCountMetadata(value: 1_000_000, accuracy: .estimated),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: 14,
                    serverDurationMilliseconds: 9),
                bytesReceived: 512,
                warnings: [warning]))

        let decoded = try modelRoundTrip(page)

        #expect(decoded == page)
        #expect(decoded.metadata.completeness.state == .partial)
        #expect(decoded.metadata.count.accuracy == .estimated)
        #expect(decoded.nextContinuation?.rawValue == "next")
    }
}
