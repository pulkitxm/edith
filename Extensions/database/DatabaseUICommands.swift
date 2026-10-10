import DatabaseCore
import Foundation

struct DatabaseUIState: Codable, Equatable, Sendable {
    let columns: Data?
    let privateContent: Bool
}

struct DatabaseUIColumns: Codable, Sendable {
    let data: Data
}

struct DatabaseUICredential: Codable, Sendable {
    let reference: DatabaseSecretReference
    let secret: Data?
}

@MainActor
final class DatabaseUICommands {
    private let sender: any DatabaseBrokerCommandSending
    private let readColumns: () -> Data?
    private let writeColumns: (Data) -> Void
    private let privateContent: () -> Bool
    private let credentials: @Sendable () throws -> any DatabaseSecretStore
    private let prepare: (DatabaseConnectionSummary) async throws -> Void
    private let repair: @Sendable () async throws -> Void

    init(
        sender: any DatabaseBrokerCommandSending,
        readColumns: @escaping () -> Data?, writeColumns: @escaping (Data) -> Void,
        privateContent: @escaping () -> Bool,
        credentials: @escaping @Sendable () throws -> any DatabaseSecretStore,
        prepare: @escaping (DatabaseConnectionSummary) async throws -> Void,
        repair: @escaping @Sendable () async throws -> Void
    ) {
        self.sender = sender
        self.readColumns = readColumns
        self.writeColumns = writeColumns
        self.privateContent = privateContent
        self.credentials = credentials
        self.prepare = prepare
        self.repair = repair
    }

    func invoke(_ operation: String, payload: Data) async throws -> Data? {
        switch operation {
        case "database.ui.state":
            try requireEmptyObject(payload)
            let columns = readColumns()
            if let columns { try DatabaseColumnsModel.validateStoredLayouts(columns) }
            return try JSONEncoder().encode(
                DatabaseUIState(columns: columns, privateContent: privateContent()))
        case "database.ui.columns":
            let request = try JSONDecoder().decode(DatabaseUIColumns.self, from: payload)
            try DatabaseColumnsModel.validateStoredLayouts(request.data)
            try Task.checkCancellation()
            writeColumns(request.data)
        case "database.ui.prepare":
            let request = try JSONDecoder().decode(DatabaseConnectionGetRequest.self, from: payload)
            let response = try await sender.send(.connectionGet(request))
            guard case .connectionGet(let result) = response,
                result.status == .succeeded, let connection = result.payload?.connection
            else { throw DatabaseBrokerCommandClientError.unavailable }
            try Task.checkCancellation()
            try await prepare(DatabaseConnectionSummary(definition: connection))
        case "database.ui.repair":
            try requireEmptyObject(payload)
            try await repair()
        case "database.ui.credential.store", "database.ui.credential.delete":
            let request = try JSONDecoder().decode(DatabaseUICredential.self, from: payload)
            guard request.reference.purpose == .password else {
                throw DatabaseBrokerCommandClientError.invalidRequest
            }
            if operation == "database.ui.credential.store" {
                guard let secret = request.secret,
                    secret.count <= DatabaseSecretStorageLimits.defaultMaximumBytes
                else { throw DatabaseBrokerCommandClientError.invalidRequest }
                try Task.checkCancellation()
                try await credentials().store(secret, for: request.reference)
            } else {
                guard request.secret == nil else {
                    throw DatabaseBrokerCommandClientError.invalidRequest
                }
                try Task.checkCancellation()
                try await credentials().delete(request.reference)
            }
        default: return nil
        }
        return Data("{\"ok\":true}".utf8)
    }

    private func requireEmptyObject(_ payload: Data) throws {
        guard payload.count <= 64,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            object.isEmpty
        else { throw DatabaseBrokerCommandClientError.invalidRequest }
    }
}
