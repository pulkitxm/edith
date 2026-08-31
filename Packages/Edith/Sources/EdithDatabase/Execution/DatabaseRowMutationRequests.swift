import Foundation

public enum DatabaseRowMutationRequestError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidIdentifier
    case duplicateField
    case missingValues
    case unsupportedIdentity
}

public enum DatabaseRowMutationRequests {
    public static func postgreSQLInsert(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try postgreSQLTable(target, requiresIdentity: false)
        try validateFields(values, excluding: [])
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let columns = values.map { quote($0.name) }.joined(separator: ", ")
        let placeholders = values.indices.map { "$\($0 + 1)" }.joined(separator: ", ")
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .postgresql,
                statement:
                    "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders)) RETURNING 1",
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    public static func postgreSQLUpdate(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try postgreSQLTable(target, requiresIdentity: true)
        let identity = try postgreSQLIdentity(target)
        try validateFields(values, excluding: Set(identity.map(\.name)))
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let assignments = values.enumerated().map { index, field in
            "\(quote(field.name)) = $\(index + 1)"
        }.joined(separator: ", ")
        let firstIdentityParameter = values.count + 1
        let predicate = identity.enumerated().map { index, component in
            "\(quote(component.name)) IS NOT DISTINCT FROM $\(firstIdentityParameter + index)"
        }.joined(separator: " AND ")
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .postgresql,
                statement:
                    "UPDATE \(table) SET \(assignments) WHERE \(predicate) RETURNING 1",
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    public static func postgreSQLDelete(
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        let table = try postgreSQLTable(target, requiresIdentity: true)
        let identity = try postgreSQLIdentity(target)
        let predicate = identity.enumerated().map { index, component in
            "\(quote(component.name)) IS NOT DISTINCT FROM $\(index + 1)"
        }.joined(separator: " AND ")
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .postgresql,
                statement: "DELETE FROM \(table) WHERE \(predicate) RETURNING 1",
                parameters: []))
    }

    private static func postgreSQLTable(
        _ target: DatabaseTargetIdentifier,
        requiresIdentity: Bool
    ) throws -> String {
        guard let object = target.object,
            object.kind == .table,
            object.path.count == 2,
            object.nativeIdentifier == nil,
            (requiresIdentity ? target.record != nil : target.record == nil)
        else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        try object.path.forEach(validateIdentifier)
        return object.path.map(quote).joined(separator: ".")
    }

    private static func postgreSQLIdentity(
        _ target: DatabaseTargetIdentifier
    ) throws -> [DatabaseIdentityComponent] {
        guard let identity = target.record,
            identity.kind == .primaryKey || identity.kind == .uniqueKey,
            (1...16).contains(identity.components.count),
            identity.concurrencyTokens.isEmpty
        else {
            throw DatabaseRowMutationRequestError.unsupportedIdentity
        }
        let names = identity.components.map(\.name)
        guard Set(names).count == names.count else {
            throw DatabaseRowMutationRequestError.unsupportedIdentity
        }
        for component in identity.components {
            try validateIdentifier(component.name)
            guard component.value != .missing, component.value != .null else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
        return identity.components
    }

    private static func validateFields(
        _ fields: [DatabaseObjectField],
        excluding excludedNames: Set<String>
    ) throws {
        guard fields.count <= 256 else {
            throw DatabaseRowMutationRequestError.missingValues
        }
        let names = fields.map(\.name)
        guard Set(names).count == names.count else {
            throw DatabaseRowMutationRequestError.duplicateField
        }
        guard Set(names).isDisjoint(with: excludedNames) else {
            throw DatabaseRowMutationRequestError.unsupportedIdentity
        }
        try names.forEach(validateIdentifier)
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 63, !value.contains("\0") else {
            throw DatabaseRowMutationRequestError.invalidIdentifier
        }
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
