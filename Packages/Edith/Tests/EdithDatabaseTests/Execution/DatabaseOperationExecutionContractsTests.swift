import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseOperationExecutionContractFixtures {
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "75F070C7-CC43-41F6-BC56-B1924987C855")!)
    static let connection = DatabaseConnectionIdentity(
        id: DatabaseConnectionID(
            rawValue: UUID(uuidString: "7EBAFEEC-BE07-4D9E-A1C5-D94806854CD4")!),
        displayName: "Orders",
        productHint: .postgresql,
        environment: DatabaseEnvironmentMetadata(
            kind: .development,
            label: "development",
            protection: .standard))
    static let summary = DatabaseOperationRecordSummary(
        id: operationID,
        kind: .databaseCapabilities,
        state: .running,
        connection: connection,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        deadline: Date(timeIntervalSince1970: 1_800_000_030),
        progress: .indeterminate(),
        cancellationSupport: .serverSide,
        retryClassification: .safeIdempotent)

    static func roundTrip<Value>(_ value: Value) throws -> Value
    where Value: Codable & Equatable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

@Suite struct DatabaseOperationExecutionContractsTests {
    @Test func getContractsPreserveStableIdentifierAndOptionalSummary() throws {
        let request = DatabaseOperationGetRequest(
            operationID: DatabaseOperationExecutionContractFixtures.operationID)
        let result = DatabaseOperationGetResult(
            operation: DatabaseOperationExecutionContractFixtures.summary)

        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(request)
                == request)
        #expect(request.version == DatabaseOperationGetRequest.schemaVersion)
        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(result)
                == result)
        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(
                DatabaseOperationGetResult(operation: nil)
            ).operation == nil)
    }

    @Test func listContractsPreserveBoundedSearchAndOrderedResults() throws {
        let search = DatabaseOperationHistorySearch(
            connectionID: DatabaseOperationExecutionContractFixtures.connection.id,
            states: [.running, .cancelling],
            kinds: [.databaseCapabilities],
            before: Date(timeIntervalSince1970: 1_800_000_100),
            limit: 25)
        let request = DatabaseOperationListRequest(search: search)
        let result = DatabaseOperationListResult(
            operations: [DatabaseOperationExecutionContractFixtures.summary])

        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(request)
                == request)
        #expect(request.version == DatabaseOperationListRequest.schemaVersion)
        #expect(request.search == search)
        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(result)
                == result)
    }

    @Test func cancelContractsPreserveDispositionSupportAndCurrentSummary() throws {
        let request = DatabaseOperationCancelRequest(
            operationID: DatabaseOperationExecutionContractFixtures.operationID)
        let result = DatabaseOperationCancelResult(
            operationID: request.operationID,
            disposition: .accepted,
            cancellationSupport: .serverSide,
            operation: DatabaseOperationExecutionContractFixtures.summary)

        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(request)
                == request)
        #expect(request.version == DatabaseOperationCancelRequest.schemaVersion)
        #expect(
            try DatabaseOperationExecutionContractFixtures.roundTrip(result)
                == result)
        #expect(result.operationID == request.operationID)
        #expect(result.disposition == .accepted)
        #expect(result.cancellationSupport == .serverSide)
    }
}
