import Foundation

enum RedisValkeyDatabaseMutationSupport {
    static let invalidMutation = failure(
        category: .invalidRequest,
        message: "The Redis-compatible key mutation is invalid.",
        code: "redis.mutation.invalid")
    static let mutationFailed = failure(
        category: .server,
        message: "The Redis-compatible key mutation could not be applied.",
        code: "redis.mutation.failed")

    static func normalize(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        let mutation = try validatedMutation(
            request,
            connectionID: connectionID,
            product: product)
        return DatabaseDestructivePlan(
            request: request,
            action: mutation.action,
            scope: mutation.scope,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: mutation.impactDescription),
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous,
            warnings: [
                DatabaseWarning(
                    code: "redis.mutation.no_rollback",
                    message: "Redis and Valkey key changes cannot be rolled back after execution.",
                    severity: .caution,
                    target: request.target)
            ])
    }

    static func execution(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> RedisValkeyDatabaseMutation {
        let normalized = try normalize(
            plan.request,
            connectionID: connectionID,
            product: product)
        guard normalized == plan else { throw invalidMutation }
        return try validatedMutation(
            plan.request,
            connectionID: connectionID,
            product: product)
    }

    static func wasApplied(
        _ reply: RedisDatabaseReply,
        operation: RedisDatabaseOperation
    ) throws(DatabaseAdapterFailure) -> Bool {
        switch operation {
        case .set:
            if case let .bytes(value) = reply {
                return value == Data("OK".utf8)
            }
            if case .null = reply { return false }
        case .delete, .expire, .persist:
            if case let .integer(value) = reply, value == 0 || value == 1 {
                return value == 1
            }
        default:
            break
        }
        throw mutationFailed
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> RedisValkeyDatabaseMutation {
        guard request.target.connectionID == connectionID,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            case let .keyspace(payloadProduct, command, arguments) = request.payload,
            payloadProduct == product
        else {
            throw invalidMutation
        }
        do {
            let canonical: DatabaseDestructiveRequest
            let operation: RedisDatabaseOperation
            let action: DatabaseDestructiveAction
            let scope: DatabaseMutationScope
            let impactDescription: String
            switch command {
            case "SET":
                guard arguments.count == 2 || arguments.count == 3,
                    arguments[0].name == "key",
                    arguments[1].name == "value"
                else { throw DatabaseKeyspaceMutationRequestError.invalidValue }
                let ttl = try setTTL(
                    arguments.dropFirst(2).first, inserting: request.target.record == nil)
                if request.target.record == nil {
                    canonical = try DatabaseKeyspaceMutationRequests.insertString(
                        target: request.target,
                        product: product,
                        key: arguments[0].value,
                        value: arguments[1].value,
                        ttlMilliseconds: ttl.milliseconds)
                    operation = .set(
                        key: try bytes(arguments[0].value),
                        value: try bytes(arguments[1].value),
                        condition: .onlyIfMissing,
                        ttl: ttl)
                    action = .insert
                    scope = .entireObject
                    impactDescription = "Create one string key"
                } else {
                    canonical = try DatabaseKeyspaceMutationRequests.updateString(
                        target: request.target,
                        product: product,
                        value: arguments[1].value,
                        ttlMilliseconds: ttl.milliseconds,
                        preservesExistingTTL: ttl == .preserve)
                    operation = .set(
                        key: try bytes(arguments[0].value),
                        value: try bytes(arguments[1].value),
                        condition: .onlyIfPresent,
                        ttl: ttl)
                    action = .update
                    scope = .singleRecord
                    impactDescription = "Update one string key"
                }
            case "PEXPIRE":
                guard arguments.count == 2,
                    arguments[0].name == "key",
                    let ttl = try ttl(arguments[1])
                else { throw DatabaseKeyspaceMutationRequestError.invalidTTL }
                canonical = try DatabaseKeyspaceMutationRequests.updateTTL(
                    target: request.target,
                    product: product,
                    ttlMilliseconds: ttl)
                operation = .expire(try bytes(arguments[0].value), milliseconds: ttl)
                action = .update
                scope = .singleRecord
                impactDescription = "Update the TTL for one key"
            case "PERSIST":
                guard arguments.count == 1, arguments[0].name == "key" else {
                    throw DatabaseKeyspaceMutationRequestError.invalidKey
                }
                canonical = try DatabaseKeyspaceMutationRequests.updateTTL(
                    target: request.target,
                    product: product,
                    ttlMilliseconds: nil)
                operation = .persist(try bytes(arguments[0].value))
                action = .update
                scope = .singleRecord
                impactDescription = "Remove the TTL from one key"
            case "DEL":
                guard arguments.count == 1, arguments[0].name == "key" else {
                    throw DatabaseKeyspaceMutationRequestError.invalidKey
                }
                canonical = try DatabaseKeyspaceMutationRequests.deleteKey(
                    target: request.target,
                    product: product)
                operation = .delete(try bytes(arguments[0].value))
                action = .delete
                scope = .singleRecord
                impactDescription = "Delete one identified key"
            default:
                throw DatabaseKeyspaceMutationRequestError.invalidTarget
            }
            guard canonical == request else { throw invalidMutation }
            return RedisValkeyDatabaseMutation(
                action: action,
                scope: scope,
                operation: operation,
                impactDescription: impactDescription)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidMutation
        }
    }

    private static func ttl(
        _ parameter: DatabaseMutationParameter?
    ) throws -> Int64? {
        guard let parameter else { return nil }
        guard parameter.name == "ttlMilliseconds",
            case let .signedInteger(value) = parameter.value,
            value > 0
        else {
            throw DatabaseKeyspaceMutationRequestError.invalidTTL
        }
        return value
    }

    private static func setTTL(
        _ parameter: DatabaseMutationParameter?,
        inserting: Bool
    ) throws -> RedisDatabaseSetTTL {
        guard let parameter else { return .persistent }
        if parameter.name == "ttlMilliseconds",
            case let .signedInteger(value) = parameter.value,
            value > 0
        {
            return .milliseconds(value)
        }
        if !inserting, parameter.name == "ttlPolicy",
            case let .string(value) = parameter.value
        {
            if value == "preserve" { return .preserve }
            if value == "persistent" { return .persistent }
        }
        throw DatabaseKeyspaceMutationRequestError.invalidTTL
    }

    private static func bytes(_ value: DatabaseValue) throws -> Data {
        switch value {
        case let .string(value):
            return Data(value.utf8)
        case let .binary(.complete(data, _, _)):
            return data
        default:
            throw DatabaseKeyspaceMutationRequestError.invalidValue
        }
    }

    private static func failure(
        category: DatabaseErrorCategory,
        message: String,
        code: String
    ) -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: category,
                message: message,
                productCode: code))
    }
}

struct RedisValkeyDatabaseMutation: Sendable {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let operation: RedisDatabaseOperation
    let impactDescription: String
}

private extension RedisDatabaseSetTTL {
    var milliseconds: Int64? {
        if case let .milliseconds(value) = self { return value }
        return nil
    }
}
