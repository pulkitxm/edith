import Foundation

public enum DatabaseKeyspaceMutationRequestError: Error, Equatable, Sendable {
    case invalidProduct
    case invalidTarget
    case invalidKey
    case invalidValue
    case invalidTTL
}

public enum DatabaseKeyspaceMutationRequests {
    public static func insertString(
        target: DatabaseTargetIdentifier,
        product: DatabaseProduct,
        key: DatabaseValue,
        value: DatabaseValue,
        ttlMilliseconds: Int64? = nil
    ) throws -> DatabaseDestructiveRequest {
        try validate(product: product, target: target, requiresIdentity: false)
        try validateKey(key)
        try validateValue(value)
        try validateTTL(ttlMilliseconds)
        var arguments = [
            DatabaseMutationParameter(name: "key", value: key),
            DatabaseMutationParameter(name: "value", value: value),
        ]
        if let ttlMilliseconds {
            arguments.append(
                DatabaseMutationParameter(
                    name: "ttlMilliseconds",
                    value: .signedInteger(ttlMilliseconds)))
        }
        return DatabaseDestructiveRequest(
            target: target,
            payload: .keyspace(product: product, command: "SET", arguments: arguments))
    }

    public static func updateString(
        target: DatabaseTargetIdentifier,
        product: DatabaseProduct,
        value: DatabaseValue,
        ttlMilliseconds: Int64? = nil,
        preservesExistingTTL: Bool = true
    ) throws -> DatabaseDestructiveRequest {
        let key = try identityKey(
            product: product,
            target: target)
        try validateValue(value)
        try validateTTL(ttlMilliseconds)
        var arguments = [
            DatabaseMutationParameter(name: "key", value: key),
            DatabaseMutationParameter(name: "value", value: value),
        ]
        if let ttlMilliseconds {
            arguments.append(
                DatabaseMutationParameter(
                    name: "ttlMilliseconds",
                    value: .signedInteger(ttlMilliseconds)))
        } else {
            arguments.append(
                DatabaseMutationParameter(
                    name: "ttlPolicy",
                    value: .string(preservesExistingTTL ? "preserve" : "persistent")))
        }
        return DatabaseDestructiveRequest(
            target: target,
            payload: .keyspace(product: product, command: "SET", arguments: arguments))
    }

    public static func updateTTL(
        target: DatabaseTargetIdentifier,
        product: DatabaseProduct,
        ttlMilliseconds: Int64?
    ) throws -> DatabaseDestructiveRequest {
        let key = try identityKey(
            product: product,
            target: target)
        try validateTTL(ttlMilliseconds)
        if let ttlMilliseconds {
            return DatabaseDestructiveRequest(
                target: target,
                payload: .keyspace(
                    product: product,
                    command: "PEXPIRE",
                    arguments: [
                        DatabaseMutationParameter(name: "key", value: key),
                        DatabaseMutationParameter(
                            name: "ttlMilliseconds",
                            value: .signedInteger(ttlMilliseconds)),
                    ]))
        }
        return DatabaseDestructiveRequest(
            target: target,
            payload: .keyspace(
                product: product,
                command: "PERSIST",
                arguments: [DatabaseMutationParameter(name: "key", value: key)]))
    }

    public static func deleteKey(
        target: DatabaseTargetIdentifier,
        product: DatabaseProduct
    ) throws -> DatabaseDestructiveRequest {
        let key = try identityKey(
            product: product,
            target: target)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .keyspace(
                product: product,
                command: "DEL",
                arguments: [DatabaseMutationParameter(name: "key", value: key)]))
    }

    private static func identityKey(
        product: DatabaseProduct,
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseValue {
        try validate(product: product, target: target, requiresIdentity: true)
        guard let identity = target.record,
            identity.kind == .key,
            identity.components.count == 1,
            identity.components[0].name == "key",
            identity.concurrencyTokens.isEmpty
        else {
            throw DatabaseKeyspaceMutationRequestError.invalidKey
        }
        let key = identity.components[0].value
        try validateKey(key)
        return key
    }

    private static func validate(
        product: DatabaseProduct,
        target: DatabaseTargetIdentifier,
        requiresIdentity: Bool
    ) throws {
        guard product == .redis || product == .valkey else {
            throw DatabaseKeyspaceMutationRequestError.invalidProduct
        }
        guard let object = target.object,
            object.kind == .keyspace,
            object.nativeIdentifier == nil,
            object.path.count <= 1,
            (requiresIdentity ? target.record != nil : target.record == nil)
        else {
            throw DatabaseKeyspaceMutationRequestError.invalidTarget
        }
    }

    private static func validateKey(_ value: DatabaseValue) throws {
        let data = try bytes(value, error: .invalidKey)
        guard !data.isEmpty, data.count <= 4_096 else {
            throw DatabaseKeyspaceMutationRequestError.invalidKey
        }
    }

    private static func validateValue(_ value: DatabaseValue) throws {
        let data = try bytes(value, error: .invalidValue)
        guard data.count <= 65_536 else {
            throw DatabaseKeyspaceMutationRequestError.invalidValue
        }
    }

    private static func validateTTL(_ value: Int64?) throws {
        guard value.map({ $0 > 0 }) ?? true else {
            throw DatabaseKeyspaceMutationRequestError.invalidTTL
        }
    }

    private static func bytes(
        _ value: DatabaseValue,
        error: DatabaseKeyspaceMutationRequestError
    ) throws -> Data {
        switch value {
        case let .string(value):
            return Data(value.utf8)
        case let .binary(.complete(data, _, _)):
            return data
        default:
            throw error
        }
    }
}
