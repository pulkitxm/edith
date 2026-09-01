import EdithDatabase
import Foundation
import Observation

enum DatabaseConnectionColorToken: String, CaseIterable, Hashable, Identifiable, Sendable {
    case blue
    case indigo
    case teal
    case green
    case purple
    case pink
    case red
    case orange

    var id: String { rawValue }
}

struct DatabaseConnectionEditDraft: Equatable, Sendable {
    let connectionID: DatabaseConnectionID
    var displayName: String
    var environmentKind: DatabaseEnvironmentKind
    var environmentLabel: String
    var environmentProtection: DatabaseEnvironmentProtection
    var readOnlyPolicy: DatabaseReadOnlyPolicy
    var productionPolicy: DatabaseProductionPolicy
    var group: String
    var tags: [String]
    var color: String?
    var isFavorite: Bool

    init(definition: DatabaseConnectionDefinition) {
        connectionID = definition.id
        displayName = definition.displayName
        environmentKind = definition.environment.kind
        environmentLabel = definition.environment.label
        environmentProtection = definition.environment.protection
        readOnlyPolicy = definition.readOnlyPolicy
        productionPolicy = definition.productionPolicy
        group = definition.group ?? ""
        tags = definition.tags
        color = definition.color
        isFavorite = definition.isFavorite
    }
}

enum DatabaseConnectionManagementOperation: String, Equatable, Sendable {
    case loadingEdit
    case savingEdit
    case renaming
    case duplicating
    case togglingFavorite
    case deleting
}

@MainActor
@Observable
final class DatabaseConnectionManagementModel {
    static let maximumFailureCharacters = 320

    private(set) var activeConnectionID: DatabaseConnectionID?
    private(set) var operation: DatabaseConnectionManagementOperation?
    private(set) var failure: String?

    private let sender: any DatabaseBrokerCommandSending

    init(sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient()) {
        self.sender = sender
    }

    var isBusy: Bool {
        operation != nil
    }

    func clearFailure() {
        failure = nil
    }

    func loadEditDraft(
        connectionID: DatabaseConnectionID
    ) async -> DatabaseConnectionEditDraft? {
        await perform(connectionID: connectionID, operation: .loadingEdit) {
            DatabaseConnectionEditDraft(
                definition: try await self.loadConnection(connectionID))
        }
    }

    func saveEditDraft(
        _ draft: DatabaseConnectionEditDraft
    ) async -> DatabaseConnectionDefinition? {
        await perform(connectionID: draft.connectionID, operation: .savingEdit) {
            let fresh = try await self.loadConnection(draft.connectionID)
            let edited = try Self.editedConnection(fresh, draft: draft)
            let response = try await self.sender.send(
                .connectionEdit(
                    DatabaseConnectionEditRequest(
                        connectionID: draft.connectionID,
                        connection: edited)))
            guard case .connectionEdit(let result) = response else {
                throw DatabaseConnectionManagementFailure.unexpectedResponse
            }
            let payload: DatabaseConnectionEditResult = try Self.payload(
                result,
                fallback: "The database connection could not be updated.")
            guard payload.connection.id == draft.connectionID else {
                throw DatabaseConnectionManagementFailure.mismatchedConnection
            }
            return payload.connection
        }
    }

    func rename(
        connectionID: DatabaseConnectionID,
        displayName: String
    ) async -> DatabaseConnectionDefinition? {
        await perform(connectionID: connectionID, operation: .renaming) {
            let name = try Self.requiredText(
                displayName,
                field: "connection name",
                maximumBytes: 512)
            let response = try await self.sender.send(
                .connectionRename(
                    DatabaseConnectionRenameRequest(
                        connectionID: connectionID,
                        displayName: name)))
            guard case .connectionRename(let result) = response else {
                throw DatabaseConnectionManagementFailure.unexpectedResponse
            }
            let payload: DatabaseConnectionRenameResult = try Self.payload(
                result,
                fallback: "The database connection could not be renamed.")
            guard payload.connection.id == connectionID else {
                throw DatabaseConnectionManagementFailure.mismatchedConnection
            }
            return payload.connection
        }
    }

    func duplicate(
        connectionID: DatabaseConnectionID,
        displayName: String
    ) async -> DatabaseConnectionDuplicateResult? {
        await perform(connectionID: connectionID, operation: .duplicating) {
            let name = try Self.requiredText(
                displayName,
                field: "connection name",
                maximumBytes: 512)
            let response = try await self.sender.send(
                .connectionDuplicate(
                    DatabaseConnectionDuplicateRequest(
                        connectionID: connectionID,
                        displayName: name)))
            guard case .connectionDuplicate(let result) = response else {
                throw DatabaseConnectionManagementFailure.unexpectedResponse
            }
            let payload: DatabaseConnectionDuplicateResult = try Self.payload(
                result,
                fallback: "The database connection could not be duplicated.")
            guard payload.sourceConnectionID == connectionID,
                payload.connection.id != connectionID
            else {
                throw DatabaseConnectionManagementFailure.mismatchedConnection
            }
            return payload
        }
    }

    func toggleFavorite(
        connectionID: DatabaseConnectionID
    ) async -> DatabaseConnectionDefinition? {
        await perform(connectionID: connectionID, operation: .togglingFavorite) {
            let fresh = try await self.loadConnection(connectionID)
            let edited = Self.connection(fresh, isFavorite: !fresh.isFavorite)
            let response = try await self.sender.send(
                .connectionEdit(
                    DatabaseConnectionEditRequest(
                        connectionID: connectionID,
                        connection: edited)))
            guard case .connectionEdit(let result) = response else {
                throw DatabaseConnectionManagementFailure.unexpectedResponse
            }
            let payload: DatabaseConnectionEditResult = try Self.payload(
                result,
                fallback: "The favorite setting could not be updated.")
            guard payload.connection.id == connectionID else {
                throw DatabaseConnectionManagementFailure.mismatchedConnection
            }
            return payload.connection
        }
    }

    func deleteConnection(
        connectionID: DatabaseConnectionID
    ) async -> DatabaseConnectionDeleteResult? {
        await perform(connectionID: connectionID, operation: .deleting) {
            let response = try await self.sender.send(
                .connectionDelete(
                    DatabaseConnectionDeleteRequest(connectionID: connectionID)))
            guard case .connectionDelete(let result) = response else {
                throw DatabaseConnectionManagementFailure.unexpectedResponse
            }
            let payload: DatabaseConnectionDeleteResult = try Self.payload(
                result,
                fallback: "The database connection could not be deleted.")
            guard payload.connectionID == connectionID else {
                throw DatabaseConnectionManagementFailure.mismatchedConnection
            }
            return payload
        }
    }

    private func perform<Value: Sendable>(
        connectionID: DatabaseConnectionID,
        operation: DatabaseConnectionManagementOperation,
        action: () async throws -> Value
    ) async -> Value? {
        guard self.operation == nil else {
            failure = Self.bounded("Another database connection change is still in progress.")
            return nil
        }
        failure = nil
        activeConnectionID = connectionID
        self.operation = operation
        defer {
            activeConnectionID = nil
            self.operation = nil
        }
        do {
            return try await action()
        } catch is CancellationError {
            return nil
        } catch {
            failure = Self.bounded(Self.message(for: error))
            return nil
        }
    }

    private func loadConnection(
        _ connectionID: DatabaseConnectionID
    ) async throws -> DatabaseConnectionDefinition {
        let response = try await sender.send(
            .connectionGet(DatabaseConnectionGetRequest(connectionID: connectionID)))
        guard case .connectionGet(let result) = response else {
            throw DatabaseConnectionManagementFailure.unexpectedResponse
        }
        let payload: DatabaseConnectionGetResult = try Self.payload(
            result,
            fallback: "The saved database connection could not be loaded.")
        guard let connection = payload.connection else {
            throw DatabaseConnectionManagementFailure.connectionNotFound
        }
        guard connection.id == connectionID else {
            throw DatabaseConnectionManagementFailure.mismatchedConnection
        }
        return connection
    }

    private static func payload<Payload: Sendable>(
        _ result: DatabaseCommandResult<Payload>,
        fallback: String
    ) throws -> Payload {
        guard result.status == .succeeded, let payload = result.payload else {
            throw DatabaseConnectionManagementFailure.service(result.error?.message ?? fallback)
        }
        return payload
    }

    private static func editedConnection(
        _ connection: DatabaseConnectionDefinition,
        draft: DatabaseConnectionEditDraft
    ) throws -> DatabaseConnectionDefinition {
        guard connection.id == draft.connectionID else {
            throw DatabaseConnectionManagementFailure.mismatchedConnection
        }
        let name = try requiredText(
            draft.displayName,
            field: "connection name",
            maximumBytes: 512)
        let environmentLabel = try requiredText(
            draft.environmentLabel,
            field: "environment label",
            maximumBytes: 512)
        let group = try optionalText(
            draft.group,
            field: "connection group",
            maximumBytes: 512)
        let tags = try normalizedTags(draft.tags)
        return DatabaseConnectionDefinition(
            version: connection.version,
            id: connection.id,
            displayName: name,
            productHint: connection.productHint,
            location: connection.location,
            username: connection.username,
            namespaces: connection.namespaces,
            deploymentMode: connection.deploymentMode,
            authentication: connection.authentication,
            tls: connection.tls,
            tunnel: connection.tunnel,
            limits: connection.limits,
            readOnlyPolicy: draft.readOnlyPolicy,
            productionPolicy: draft.productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: draft.environmentKind,
                label: environmentLabel,
                protection: draft.environmentProtection),
            group: group,
            tags: tags,
            color: draft.color,
            isFavorite: draft.isFavorite,
            options: connection.options,
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt,
            lastTestedAt: connection.lastTestedAt,
            lastUsedAt: connection.lastUsedAt)
    }

    private static func connection(
        _ source: DatabaseConnectionDefinition,
        isFavorite: Bool
    ) -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            version: source.version,
            id: source.id,
            displayName: source.displayName,
            productHint: source.productHint,
            location: source.location,
            username: source.username,
            namespaces: source.namespaces,
            deploymentMode: source.deploymentMode,
            authentication: source.authentication,
            tls: source.tls,
            tunnel: source.tunnel,
            limits: source.limits,
            readOnlyPolicy: source.readOnlyPolicy,
            productionPolicy: source.productionPolicy,
            environment: source.environment,
            group: source.group,
            tags: source.tags,
            color: source.color,
            isFavorite: isFavorite,
            options: source.options,
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
            lastTestedAt: source.lastTestedAt,
            lastUsedAt: source.lastUsedAt)
    }

    private static func normalizedTags(_ values: [String]) throws -> [String] {
        var normalized: [String] = []
        var keys: Set<String> = []
        for value in values {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            guard tag.utf8.count <= 128 else {
                throw DatabaseConnectionManagementFailure.invalidField("tag")
            }
            let key = tag.lowercased()
            if keys.insert(key).inserted {
                normalized.append(tag)
            }
        }
        guard normalized.count <= 64 else {
            throw DatabaseConnectionManagementFailure.tooManyTags
        }
        return normalized
    }

    private static func requiredText(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= maximumBytes else {
            throw DatabaseConnectionManagementFailure.invalidField(field)
        }
        return normalized
    }

    private static func optionalText(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= maximumBytes else {
            throw DatabaseConnectionManagementFailure.invalidField(field)
        }
        return normalized
    }

    private static func message(for error: Error) -> String {
        if let clientError = error as? DatabaseBrokerCommandClientError {
            return switch clientError {
            case .invalidRequest:
                "The database service rejected the connection request."
            case .timedOut:
                "The database connection request timed out."
            case .unavailable:
                "The local database service is unavailable."
            case .unsafePeer:
                "The local database service could not be verified."
            case .outcomeUnknown:
                "The database connection change may have completed, but its outcome could not be confirmed."
            }
        }
        if let localized = error as? LocalizedError,
            let description = localized.errorDescription
        {
            return description
        }
        return "The database connection change could not be completed."
    }

    private static func bounded(_ message: String) -> String {
        let normalized = message.split(whereSeparator: \Character.isWhitespace).joined(
            separator: " ")
        guard normalized.count > maximumFailureCharacters else { return normalized }
        return String(normalized.prefix(maximumFailureCharacters - 1)) + "…"
    }
}

private enum DatabaseConnectionManagementFailure: LocalizedError {
    case connectionNotFound
    case invalidField(String)
    case mismatchedConnection
    case service(String)
    case tooManyTags
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .connectionNotFound:
            "The saved database connection no longer exists."
        case .invalidField(let field):
            "Enter a valid \(field)."
        case .mismatchedConnection:
            "The database service returned a different connection."
        case .service(let message):
            message
        case .tooManyTags:
            "Use no more than 64 connection tags."
        case .unexpectedResponse:
            "The database service returned an unexpected response."
        }
    }
}
