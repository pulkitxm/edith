import Foundation

public enum DatabaseSecretStoreOperation: String, CaseIterable, Hashable, Sendable {
    case store
    case read
    case delete
    case contains
}

public enum DatabaseSecretStoreError: Error, Equatable, Sendable {
    case invalidService
    case invalidLabel
    case invalidMaximumSecretBytes
    case secretTooLarge(actualBytes: Int, maximumBytes: Int)
    case storedSecretTooLarge(reference: DatabaseSecretReference, maximumBytes: Int)
    case notFound(DatabaseSecretReference)
    case invalidStoredData(DatabaseSecretReference)
    case keychainFailure(operation: DatabaseSecretStoreOperation, status: Int32)
}

extension DatabaseSecretStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidService:
            "The secret service identifier is invalid."
        case .invalidLabel:
            "The secret service label is invalid."
        case .invalidMaximumSecretBytes:
            "The secret size limit is invalid."
        case let .secretTooLarge(actualBytes, maximumBytes):
            "The secret uses \(actualBytes) bytes, exceeding the \(maximumBytes) byte limit."
        case let .storedSecretTooLarge(_, maximumBytes):
            "The stored secret exceeds the \(maximumBytes) byte limit."
        case .notFound:
            "The requested secret was not found."
        case .invalidStoredData:
            "The stored secret has an invalid representation."
        case let .keychainFailure(operation, status):
            "The Keychain \(operation.rawValue) operation failed with status \(status)."
        }
    }
}

public enum DatabaseSecretStorageLimits {
    public static let defaultMaximumBytes = 65_536
    public static let absoluteMaximumBytes = 1_048_576
}

public protocol DatabaseSecretStore: Sendable {
    func store(_ secret: Data, for reference: DatabaseSecretReference) async throws
    func storeIfAbsent(_ secret: Data, for reference: DatabaseSecretReference) async throws -> Data
    func read(_ reference: DatabaseSecretReference) async throws -> Data
    func delete(_ reference: DatabaseSecretReference) async throws
    func contains(_ reference: DatabaseSecretReference) async throws -> Bool
}

public actor InMemoryDatabaseSecretStore: DatabaseSecretStore {
    public nonisolated let maximumSecretBytes: Int
    private var values: [DatabaseSecretReference: Data]

    public init(
        initialValues: [DatabaseSecretReference: Data] = [:],
        maximumSecretBytes: Int = DatabaseSecretStorageLimits.defaultMaximumBytes
    ) throws {
        guard (1...DatabaseSecretStorageLimits.absoluteMaximumBytes).contains(maximumSecretBytes)
        else {
            throw DatabaseSecretStoreError.invalidMaximumSecretBytes
        }
        if let oversized = initialValues.first(where: { $0.value.count > maximumSecretBytes }) {
            throw DatabaseSecretStoreError.secretTooLarge(
                actualBytes: oversized.value.count,
                maximumBytes: maximumSecretBytes)
        }
        self.maximumSecretBytes = maximumSecretBytes
        values = initialValues
    }

    public func store(_ secret: Data, for reference: DatabaseSecretReference) throws {
        try validate(secret)
        values[reference] = secret
    }

    public func storeIfAbsent(
        _ secret: Data,
        for reference: DatabaseSecretReference
    ) throws -> Data {
        try validate(secret)
        if let existing = values[reference] { return existing }
        values[reference] = secret
        return secret
    }

    public func read(_ reference: DatabaseSecretReference) throws -> Data {
        guard let secret = values[reference] else {
            throw DatabaseSecretStoreError.notFound(reference)
        }
        return secret
    }

    public func delete(_ reference: DatabaseSecretReference) throws {
        guard values.removeValue(forKey: reference) != nil else {
            throw DatabaseSecretStoreError.notFound(reference)
        }
    }

    public func contains(_ reference: DatabaseSecretReference) -> Bool {
        values[reference] != nil
    }

    private func validate(_ secret: Data) throws {
        guard secret.count <= maximumSecretBytes else {
            throw DatabaseSecretStoreError.secretTooLarge(
                actualBytes: secret.count,
                maximumBytes: maximumSecretBytes)
        }
    }
}
