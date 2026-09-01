import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite("Database connection management")
struct DatabaseConnectionManagementModelTests {
    @Test("Loading an edit draft uses the saved connection")
    func loadEditDraft() async throws {
        let connection = try Self.connection(
            name: "Orders",
            group: "Commerce",
            tags: ["Critical", "Orders"],
            color: "purple",
            isFavorite: true)
        let sender = DatabaseConnectionManagementSender([
            .response(Self.getResponse(connection))
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)

        let draft = await model.loadEditDraft(connectionID: connection.id)

        #expect(draft?.connectionID == connection.id)
        #expect(draft?.displayName == "Orders")
        #expect(draft?.environmentKind == .staging)
        #expect(draft?.environmentLabel == "Staging east")
        #expect(draft?.environmentProtection == .confirmationRequired)
        #expect(draft?.readOnlyPolicy == .required)
        #expect(draft?.productionPolicy == .requireMutationPreview)
        #expect(draft?.group == "Commerce")
        #expect(draft?.tags == ["Critical", "Orders"])
        #expect(draft?.colorToken == .purple)
        #expect(draft?.isFavorite == true)
        #expect(model.activeConnectionID == nil)
        #expect(model.operation == nil)
        #expect(model.failure == nil)
        let requests = await sender.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].connectionGetRequest?.connectionID == connection.id)
    }

    @Test("Saving reloads the connection and preserves fresh private fields")
    func saveUsesFreshConnection() async throws {
        let original = try Self.connection(
            name: "Orders old",
            host: "old.internal",
            credentialSeed: 40,
            group: "Old group",
            tags: ["old"],
            color: "blue")
        let fresh = try Self.connection(
            name: "Orders current",
            host: "fresh.internal",
            credentialSeed: 70,
            group: "Current group",
            tags: ["current"],
            color: "orange")
        let credential = try #require(fresh.authentication.secretReferences.first)
        let credentialMaterial = "vault-password-never-send"
        let secretStore = try InMemoryDatabaseSecretStore(
            initialValues: [credential: Data(credentialMaterial.utf8)])
        let sender = DatabaseConnectionManagementSender([
            .response(Self.getResponse(original)),
            .response(Self.getResponse(fresh)),
            .echoEdit,
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)
        var draft = try #require(await model.loadEditDraft(connectionID: original.id))
        draft.displayName = "  Orders primary  "
        draft.environmentKind = .production
        draft.environmentLabel = "  Production east  "
        draft.environmentProtection = .readOnly
        draft.readOnlyPolicy = .required
        draft.productionPolicy = .prohibitMutations
        draft.group = "  Payments  "
        draft.tags = [" Critical ", "critical", "Orders", "orders ", ""]
        draft.colorToken = .teal
        draft.isFavorite = true

        let saved = await model.saveEditDraft(draft)

        #expect(saved?.displayName == "Orders primary")
        #expect(saved?.environment.kind == .production)
        #expect(saved?.environment.label == "Production east")
        #expect(saved?.environment.protection == .readOnly)
        #expect(saved?.readOnlyPolicy == .required)
        #expect(saved?.productionPolicy == .prohibitMutations)
        #expect(saved?.group == "Payments")
        #expect(saved?.tags == ["Critical", "Orders"])
        #expect(saved?.color == "teal")
        #expect(saved?.isFavorite == true)
        let requests = await sender.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].connectionGetRequest?.connectionID == original.id)
        #expect(requests[1].connectionGetRequest?.connectionID == original.id)
        let edited = try #require(requests[2].connectionEditRequest?.connection)
        #expect(edited.location == fresh.location)
        #expect(edited.username == fresh.username)
        #expect(edited.namespaces == fresh.namespaces)
        #expect(edited.deploymentMode == fresh.deploymentMode)
        #expect(edited.authentication == fresh.authentication)
        #expect(edited.tls == fresh.tls)
        #expect(edited.tunnel == fresh.tunnel)
        #expect(edited.limits == fresh.limits)
        #expect(edited.options == fresh.options)
        #expect(edited.createdAt == fresh.createdAt)
        #expect(edited.updatedAt == fresh.updatedAt)
        #expect(edited.lastTestedAt == fresh.lastTestedAt)
        #expect(edited.lastUsedAt == fresh.lastUsedAt)
        let encoded = try JSONEncoder().encode(edited)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(credentialMaterial))
        #expect(try await secretStore.read(credential) == Data(credentialMaterial.utf8))
        #expect(model.failure == nil)
    }

    @Test("Favorite toggling fetches fresh state and changes no other fields")
    func toggleFavoriteUsesFreshConnection() async throws {
        let fresh = try Self.connection(
            name: "Inventory",
            host: "inventory.internal",
            credentialSeed: 90,
            group: "Supply",
            tags: ["warehouse"],
            color: "green",
            isFavorite: false)
        let sender = DatabaseConnectionManagementSender([
            .response(Self.getResponse(fresh)),
            .echoEdit,
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)

        let updated = await model.toggleFavorite(connectionID: fresh.id)

        #expect(updated?.isFavorite == true)
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].connectionGetRequest?.connectionID == fresh.id)
        let edit = try #require(requests[1].connectionEditRequest)
        #expect(edit.connectionID == fresh.id)
        #expect(edit.connection.displayName == fresh.displayName)
        #expect(edit.connection.location == fresh.location)
        #expect(edit.connection.authentication == fresh.authentication)
        #expect(edit.connection.tls == fresh.tls)
        #expect(edit.connection.tunnel == fresh.tunnel)
        #expect(edit.connection.limits == fresh.limits)
        #expect(edit.connection.namespaces == fresh.namespaces)
        #expect(edit.connection.options == fresh.options)
        #expect(edit.connection.group == fresh.group)
        #expect(edit.connection.tags == fresh.tags)
        #expect(edit.connection.color == fresh.color)
        #expect(edit.connection.isFavorite == true)
    }

    @Test("Duplicate returns the shared credential result")
    func duplicateReturnsFullResult() async throws {
        let source = try Self.connection(name: "Orders", credentialSeed: 110)
        let duplicate = try Self.connection(
            id: 2,
            name: "Orders copy",
            credentialSeed: 110)
        let reference = try #require(source.authentication.secretReferences.first)
        let expected = DatabaseConnectionDuplicateResult(
            sourceConnectionID: source.id,
            connection: duplicate,
            sharesCredentials: true,
            sharedCredentialReferences: [reference])
        let sender = DatabaseConnectionManagementSender([
            .response(
                .connectionDuplicate(
                    .success(expected, metadata: Self.completeMetadata)))
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)

        let result = await model.duplicate(
            connectionID: source.id,
            displayName: "  Orders copy  ")

        #expect(result == expected)
        #expect(result?.sharesCredentials == true)
        #expect(result?.sharedCredentialReferences == [reference])
        let request = try #require(
            (await sender.recordedRequests()).first?.connectionDuplicateRequest)
        #expect(request.connectionID == source.id)
        #expect(request.displayName == "Orders copy")
        #expect(model.operation == nil)
    }

    @Test("Rename and delete use their dedicated contracts")
    func renameAndDelete() async throws {
        let source = try Self.connection(name: "Orders")
        let renamed = try Self.connection(name: "Orders primary")
        let sender = DatabaseConnectionManagementSender([
            .response(
                .connectionRename(
                    .success(
                        DatabaseConnectionRenameResult(connection: renamed),
                        metadata: Self.completeMetadata))),
            .response(
                .connectionDelete(
                    .success(
                        DatabaseConnectionDeleteResult(
                            connectionID: source.id,
                            deleted: true,
                            disconnected: true),
                        metadata: Self.completeMetadata))),
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)

        let renameResult = await model.rename(
            connectionID: source.id,
            displayName: "  Orders primary  ")
        let deleteResult = await model.deleteConnection(connectionID: source.id)

        #expect(renameResult == renamed)
        #expect(deleteResult?.deleted == true)
        #expect(deleteResult?.disconnected == true)
        let requests = await sender.recordedRequests()
        #expect(requests[0].connectionRenameRequest?.displayName == "Orders primary")
        #expect(requests[1].connectionDeleteRequest?.connectionID == source.id)
    }

    @Test("Failures are actionable, bounded and clearable")
    func failureMapping() async throws {
        let connection = try Self.connection(name: "Orders")
        let longMessage = String(repeating: "failure detail ", count: 80) + "\nnext line"
        let sender = DatabaseConnectionManagementSender([
            .failure(.timedOut),
            .response(
                .connectionRename(
                    .failure(
                        DatabaseErrorEnvelope(
                            category: .invalidRequest,
                            message: longMessage),
                        metadata: Self.completeMetadata))),
        ])
        let model = DatabaseConnectionManagementModel(sender: sender)

        let draft = await model.loadEditDraft(connectionID: connection.id)

        #expect(draft == nil)
        #expect(model.failure == "The database connection request timed out.")
        model.clearFailure()
        #expect(model.failure == nil)

        let renamed = await model.rename(
            connectionID: connection.id,
            displayName: "Orders primary")

        #expect(renamed == nil)
        let failure = try #require(model.failure)
        #expect(failure.count == DatabaseConnectionManagementModel.maximumFailureCharacters)
        #expect(!failure.contains("\n"))
        #expect(failure.hasSuffix("…"))
        #expect(model.activeConnectionID == nil)
        #expect(model.operation == nil)
    }

    private static let completeMetadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))

    private static func getResponse(
        _ connection: DatabaseConnectionDefinition
    ) -> DatabaseBrokerCommandResponse {
        .connectionGet(
            .success(
                DatabaseConnectionGetResult(connection: connection),
                metadata: completeMetadata))
    }

    private static func connection(
        id: UInt8 = 1,
        name: String,
        host: String = "db.internal",
        credentialSeed: UInt8 = 20,
        group: String? = "Payments",
        tags: [String] = ["critical", "orders"],
        color: String? = "indigo",
        isFavorite: Bool = false
    ) throws -> DatabaseConnectionDefinition {
        let password = DatabaseSecretReference(
            identifier: uuid(credentialSeed),
            purpose: .password)
        let privateKey = DatabaseSecretReference(
            identifier: uuid(credentialSeed + 1),
            purpose: .clientPrivateKey)
        return DatabaseConnectionDefinition(
            id: DatabaseConnectionID(rawValue: uuid(id)),
            displayName: name,
            productHint: .postgresql,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: host,
                    port: try DatabasePort(6_432),
                    role: .primary),
                DatabaseNetworkEndpoint(
                    host: "replica.\(host)",
                    port: try DatabasePort(6_433),
                    role: .readReplica),
            ]),
            username: "database-owner",
            namespaces: DatabaseNamespaceDefaults(
                catalog: "application",
                schema: "public",
                database: "orders"),
            deploymentMode: .primaryReplica,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [password],
                source: "identity-provider"),
            tls: DatabaseTLSConfiguration(
                mode: .required,
                verification: .full,
                serverName: host,
                certificateAuthority: DatabaseResourceReference(
                    identifier: uuid(credentialSeed + 2),
                    kind: .certificateAuthority),
                clientCertificate: DatabaseResourceReference(
                    identifier: uuid(credentialSeed + 3),
                    kind: .clientCertificate),
                clientPrivateKey: privateKey),
            tunnel: DatabaseTunnelDefinition(
                machineIdentifier: "tuf-windows",
                remoteEndpoint: DatabaseNetworkEndpoint(
                    host: host,
                    port: try DatabasePort(6_432)),
                localBindAddress: "127.0.0.1",
                requestedLocalPort: try DatabasePort(16_432),
                managesLifecycle: true),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 8_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 45_000),
                poolSize: try DatabasePoolSize(6),
                idleTimeout: try DatabaseTimeout(milliseconds: 120_000),
                keepaliveInterval: try DatabaseTimeout(milliseconds: 30_000)),
            readOnlyPolicy: .required,
            productionPolicy: .requireMutationPreview,
            environment: DatabaseEnvironmentMetadata(
                kind: .staging,
                label: "Staging east",
                protection: .confirmationRequired),
            group: group,
            tags: tags,
            color: color,
            isFavorite: isFavorite,
            options: [
                DatabaseNonSecretOption(name: "applicationName", value: .string("Edith")),
                DatabaseNonSecretOption(name: "loadBalance", value: .boolean(true)),
            ],
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            lastTestedAt: Date(timeIntervalSince1970: 2_500),
            lastUsedAt: Date(timeIntervalSince1970: 3_000))
    }

    private static func uuid(_ value: UInt8) -> UUID {
        UUID(
            uuid: (
                0x94, 0xD8, 0x24, 0x1B, 0x88, 0x74, 0x46, 0x32,
                0xA4, 0x51, 0x8B, 0x62, 0x71, 0x00, 0x00, value
            ))
    }
}

private actor DatabaseConnectionManagementSender: DatabaseBrokerCommandSending {
    enum Outcome: Sendable {
        case echoEdit
        case failure(DatabaseBrokerCommandClientError)
        case response(DatabaseBrokerCommandResponse)
    }

    private var outcomes: [Outcome]
    private var requests: [DatabaseBrokerCommandRequest] = []

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func send(
        _ request: DatabaseBrokerCommandRequest
    ) async throws -> DatabaseBrokerCommandResponse {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw DatabaseBrokerCommandClientError.invalidRequest
        }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .echoEdit:
            guard case .connectionEdit(let edit) = request else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            return .connectionEdit(
                .success(
                    DatabaseConnectionEditResult(connection: edit.connection),
                    metadata: DatabaseResultMetadata(
                        completeness: DatabaseResultCompleteness(state: .complete))))
        case .failure(let error):
            throw error
        case .response(let response):
            return response
        }
    }

    func recordedRequests() -> [DatabaseBrokerCommandRequest] {
        requests
    }
}
