import EdithCore
import Foundation

public extension DatabaseRowMutationRequests {
    static func sqliteInsert(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: false)
        try validateSQLiteMutationFields(values, excluding: [])
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let columns = values.map { sqliteMutationQuote($0.name) }.joined(separator: ", ")
        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
        let statement = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    static func sqliteUpdate(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: true)
        let identity = try sqliteMutationIdentity(target)
        try validateSQLiteMutationFields(
            values,
            excluding: Set(identity.map { sqliteMutationFold($0.name) }))
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let assignments = values.map {
            "\(sqliteMutationQuote($0.name)) = ?"
        }.joined(separator: ", ")
        let predicate = identity.map {
            "\(sqliteMutationQuote($0.name)) IS ?"
        }.joined(separator: " AND ")
        let statement = "UPDATE \(table) SET \(assignments) WHERE \(predicate)"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    static func sqliteDelete(
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: true)
        let identity = try sqliteMutationIdentity(target)
        let predicate = identity.map {
            "\(sqliteMutationQuote($0.name)) IS ?"
        }.joined(separator: " AND ")
        let statement = "DELETE FROM \(table) WHERE \(predicate)"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: []))
    }

    private static func sqliteMutationTable(
        _ target: DatabaseTargetIdentifier,
        requiresIdentity: Bool
    ) throws -> String {
        guard let object = target.object,
            object.kind == .table,
            object.nativeIdentifier == nil,
            object.path.count == 1 || object.path.count == 2,
            (requiresIdentity ? target.record != nil : target.record == nil)
        else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        let schema = object.path.count == 1 ? "main" : object.path[0].lowercased()
        let table = object.path.last ?? ""
        guard schema == "main" || schema == "temp" else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        try validateSQLiteMutationIdentifier(table)
        return "\(sqliteMutationQuote(schema)).\(sqliteMutationQuote(table))"
    }

    private static func sqliteMutationIdentity(
        _ target: DatabaseTargetIdentifier
    ) throws -> [DatabaseIdentityComponent] {
        guard let identity = target.record,
            identity.kind == .primaryKey || identity.kind == .rowID,
            (1...16).contains(identity.components.count),
            identity.concurrencyTokens.isEmpty
        else {
            throw DatabaseRowMutationRequestError.unsupportedIdentity
        }
        if identity.kind == .rowID {
            guard identity.components.count == 1,
                ["rowid", "_rowid_", "oid"].contains(
                    sqliteMutationFold(identity.components[0].name)),
                case .signedInteger = identity.components[0].value
            else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
        var names = Set<String>()
        for component in identity.components {
            try validateSQLiteMutationIdentifier(component.name)
            guard names.insert(sqliteMutationFold(component.name)).inserted,
                component.value != .missing,
                component.value != .null
            else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
        return identity.components
    }

    private static func validateSQLiteMutationFields(
        _ fields: [DatabaseObjectField],
        excluding excludedNames: Set<String>
    ) throws {
        guard fields.count <= 256 else {
            throw DatabaseRowMutationRequestError.missingValues
        }
        var names = Set<String>()
        for field in fields {
            try validateSQLiteMutationIdentifier(field.name)
            let folded = sqliteMutationFold(field.name)
            guard names.insert(folded).inserted else {
                throw DatabaseRowMutationRequestError.duplicateField
            }
            guard !excludedNames.contains(folded) else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
    }

    private static func validateSQLiteMutationIdentifier(_ value: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw DatabaseRowMutationRequestError.invalidIdentifier
        }
    }

    private static func validateSQLiteMutationStatement(_ statement: String) throws {
        guard statement.utf8.count <= 65_536 else {
            throw DatabaseRowMutationRequestError.invalidIdentifier
        }
    }

    private static func sqliteMutationQuote(_ value: String) -> String {
        DoubleQuoted.wrap(value)
    }

    private static func sqliteMutationFold(_ identifier: String) -> String {
        let scalars = identifier.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(scalar.value + 32) ?? scalar
                : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
