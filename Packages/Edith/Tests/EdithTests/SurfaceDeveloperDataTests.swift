import EdithDatabase
import Foundation
import Testing

@testable import EdithKit

struct SurfaceDeveloperDataTests {
    @Test func pullRequestsDeduplicateRolesAndRespectSelections() throws {
        let data = try fixture()
        var tile = SurfaceTile(.github)
        let snapshot = try SurfaceGitHubClient.project(data, tile: tile)
        #expect(snapshot.metrics.first { $0.id == "pulls" }?.value == "2")
        #expect(snapshot.metrics.first { $0.id == "review" }?.value == "1")
        #expect(snapshot.metrics.first { $0.id == "failed" }?.value == "1")
        #expect(snapshot.rows.first?.id == "one")
        #expect(snapshot.rows.first?.detail.contains("Review requested") == true)
        #expect(snapshot.rows.first?.actions.count == 1)
        tile.contentKinds = ["assigned"]
        tile.sourceIDs = ["sample/tools"]
        let filtered = try SurfaceGitHubClient.project(data, tile: tile)
        #expect(filtered.rows.map(\.id) == ["two"])
        tile.contentKinds = []
        #expect(try SurfaceGitHubClient.project(data, tile: tile).rows.isEmpty)
        tile.contentKinds = nil
        tile.sourceIDs = []
        #expect(try SurfaceGitHubClient.project(data, tile: tile).rows.isEmpty)
    }
    @Test func partialGraphQLErrorsDoNotPretendToBeSuccessful() throws {
        let data = try fixture(error: true)
        #expect(throws: SurfaceGitHubError.self) {
            try SurfaceGitHubClient.project(data, tile: SurfaceTile(.github))
        }
        #expect(
            try SurfaceGitHubClient.project(fixture(limited: true), tile: SurfaceTile(.github))
                .message?.contains("50") == true)
    }
    @Test func githubReadsUseBoundedNoninteractiveRequests() {
        let request = SurfaceGitHubClient.request(
            ["api", "user"], executable: URL(fileURLWithPath: "/tmp/gh"))
        #expect(request.timeout == 30)
        #expect(request.maximumOutputBytes == 1 << 20)
        #expect(request.environment["GH_PROMPT_DISABLED"] == "1")
        #expect(request.environment["GH_NO_UPDATE_NOTIFIER"] == "1")
        #expect(request.terminatesProcessGroup)
    }
    @Test func sourceIdentityDistinguishesAllFromNoneAndDoesNotUseDelimiters() {
        var tile = SurfaceTile(.github)
        let all = SurfaceExtensionRequestKey(tile)
        tile.sourceIDs = []
        #expect(all != SurfaceExtensionRequestKey(tile))
        tile.sourceIDs = ["a|b"]
        let first = SurfaceExtensionRequestKey(tile)
        tile.sourceIDs = ["a", "b"]
        #expect(first != SurfaceExtensionRequestKey(tile))
        let sources = SurfaceExtensionRequestKey(tile)
        tile.contentKinds = []
        #expect(sources != SurfaceExtensionRequestKey(tile))
    }
    @Test func databaseCardShowsMetadataWithoutQueryTextOrPasswords() throws {
        let connection = try DatabaseConnectionDraft(
            displayName: "Example database", product: .elasticsearch,
            host: "search.example.com", environmentKind: .testing, environmentLabel: "Test",
            environmentProtection: .standard, readOnlyPolicy: .disabled, productionPolicy: .standard
        ).definition()
        let query = DatabaseSavedQuery(
            id: .init(), connectionID: connection.id, name: "Weekly totals", language: .sql,
            text: "SELECT secret_value FROM internal_table", createdAt: .now, updatedAt: .now)
        let operation = DatabaseOperationRecordSummary(
            id: .init(), kind: "query", state: .running,
            connection: connection.identity,
            progress: .determinate(completed: 2, total: 4, unit: .pages),
            cancellationSupport: .cooperative, retryClassification: .never)
        var tile = SurfaceTile(.databases)
        let value = SurfaceDatabaseClient.project(
            connections: [connection], queries: [query], operations: [operation], tile: tile)
        #expect(value.metrics.first { $0.id == "running" }?.value == "1")
        #expect(value.rows.first?.progress == 0.5)
        #expect(!String(describing: value).contains("secret_value"))
        #expect(!String(describing: value).contains("search.example.com"))
        tile.contentKinds = ["queries"]
        #expect(
            SurfaceDatabaseClient.project(
                connections: [connection], queries: [query], operations: [operation], tile: tile
            ).rows.map(\.title) == ["Weekly totals"])
        tile.sourceIDs = []
        #expect(
            SurfaceDatabaseClient.project(
                connections: [connection], queries: [query], operations: [operation], tile: tile
            ).rows.isEmpty)
    }
    @Test func missingDatabasePackNeverStartsOrInstallsService() async throws {
        let value = try await SurfaceDatabaseClient(
            client: RejectingDatabaseClient(), packReady: { false }
        ).snapshot(SurfaceTile(.databases))
        #expect(value.message?.contains("set up") == true)
        #expect(value.actions.count == 1)
    }
    @Test func databaseUsesOnlyMetadataReadCommandsAndRejectsPartialResults() async throws {
        let tile = SurfaceTile(.databases)
        let value = try await SurfaceDatabaseClient(
            client: MetadataDatabaseClient(partial: false), packReady: { true }
        ).snapshot(tile)
        #expect(value.rows.isEmpty)
        await #expect(throws: SurfaceDatabaseError.self) {
            try await SurfaceDatabaseClient(
                client: MetadataDatabaseClient(partial: true), packReady: { true }
            ).snapshot(tile)
        }
    }
    private struct MetadataDatabaseClient: DatabaseBrokerCommandSending {
        let partial: Bool
        func send(_ request: DatabaseBrokerCommandRequest) async throws
            -> DatabaseBrokerCommandResponse
        {
            let metadata = DatabaseResultMetadata(completeness: .init(state: .complete))
            switch request {
            case .connectionList:
                let payload = DatabaseConnectionListResult(connections: [])
                return .connectionList(
                    partial
                        ? .partial(payload, metadata: metadata)
                        : .success(payload, metadata: metadata))
            case .savedQueryList:
                return .savedQueryList(.success(.init(queries: []), metadata: metadata))
            case .operationList:
                return .operationList(.success(.init(operations: []), metadata: metadata))
            default:
                Issue.record("The card sent a command other than a metadata read")
                throw SurfaceDatabaseError.incompleteResponse
            }
        }
    }
    private struct RejectingDatabaseClient: DatabaseBrokerCommandSending {
        func send(_ request: DatabaseBrokerCommandRequest) async throws
            -> DatabaseBrokerCommandResponse
        {
            Issue.record("The widget must not contact a missing database pack")
            throw SurfaceDatabaseError.incompleteResponse
        }
    }
    private func fixture(error: Bool = false, limited: Bool = false) throws -> Data {
        func pull(_ id: String, _ repository: String, _ check: String, _ review: String) -> [String:
            Any]
        {
            [
                "id": id, "title": "Sample change",
                "url": "https://github.com/" + repository + "/pull/1",
                "number": 1, "isDraft": false, "updatedAt": "2026-10-09T00:00:00Z",
                "reviewDecision": review,
                "repository": ["nameWithOwner": repository],
                "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": check]]]]],
            ]
        }
        let one = pull("one", "sample/app", "FAILURE", "REVIEW_REQUIRED")
        let two = pull("two", "sample/tools", "SUCCESS", "APPROVED")
        func group(_ items: [[String: Any]]) -> [String: Any] {
            ["nodes": items, "pageInfo": ["hasNextPage": limited]]
        }
        var response: [String: Any] = [
            "data": ["authored": group([one]), "review": group([one]), "assigned": group([two])]
        ]
        if error { response["errors"] = [["message": "Sample API error"]] }
        return try JSONSerialization.data(withJSONObject: response)
    }
}
