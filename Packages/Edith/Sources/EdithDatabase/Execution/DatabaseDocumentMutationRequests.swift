import Foundation

public enum DatabaseDocumentMutationRequestError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidIdentity
    case invalidDocument
    case duplicateField
    case missingValues
}

public enum DatabaseDocumentMutationRequests {
    public static func elasticsearchCreate(
        target: DatabaseTargetIdentifier,
        document: DatabaseValue
    ) throws -> DatabaseDestructiveRequest {
        _ = try searchIdentity(target, requiresConcurrency: false)
        try validateSearchDocument(document)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .elasticsearch,
                operation: "create",
                parameters: [],
                body: document))
    }

    public static func elasticsearchReplace(
        target: DatabaseTargetIdentifier,
        document: DatabaseValue
    ) throws -> DatabaseDestructiveRequest {
        _ = try searchIdentity(target, requiresConcurrency: true)
        try validateSearchDocument(document)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .elasticsearch,
                operation: "replace",
                parameters: [],
                body: document))
    }

    public static func elasticsearchDelete(
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        _ = try searchIdentity(target, requiresConcurrency: true)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .elasticsearch,
                operation: "delete",
                parameters: [],
                body: .null))
    }

    public static func mongoDBInsert(
        target: DatabaseTargetIdentifier,
        document: DatabaseValue
    ) throws -> DatabaseDestructiveRequest {
        try validateTarget(target, requiresIdentity: false)
        try validateDocument(document, allowsIdentifier: true)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .mongoDB,
                operation: "insertOne",
                parameters: [],
                body: document))
    }

    public static func mongoDBUpdate(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        try validateTarget(target, requiresIdentity: true)
        _ = try identityValue(target)
        try validateFields(values, allowsIdentifier: false)
        guard !values.isEmpty else {
            throw DatabaseDocumentMutationRequestError.missingValues
        }
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .mongoDB,
                operation: "updateOne",
                parameters: [],
                body: .object(values)))
    }

    public static func mongoDBDelete(
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        try validateTarget(target, requiresIdentity: true)
        _ = try identityValue(target)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .document(
                product: .mongoDB,
                operation: "deleteOne",
                parameters: [],
                body: .null))
    }

    static func mongoDBIdentityValue(
        _ target: DatabaseTargetIdentifier
    ) throws -> DatabaseValue {
        try identityValue(target)
    }

    static func elasticsearchIdentity(
        _ target: DatabaseTargetIdentifier,
        requiresConcurrency: Bool
    ) throws -> DatabaseSearchDocumentIdentity {
        try searchIdentity(target, requiresConcurrency: requiresConcurrency)
    }

    private static func validateTarget(
        _ target: DatabaseTargetIdentifier,
        requiresIdentity: Bool
    ) throws {
        guard let object = target.object,
            object.kind == .collection,
            object.path.count == 2,
            object.nativeIdentifier == nil,
            object.path.allSatisfy(validNamespace),
            (requiresIdentity ? target.record != nil : target.record == nil)
        else {
            throw DatabaseDocumentMutationRequestError.invalidTarget
        }
    }

    private static func identityValue(
        _ target: DatabaseTargetIdentifier
    ) throws -> DatabaseValue {
        guard let identity = target.record,
            identity.kind == .documentID,
            identity.components.count == 1,
            identity.components[0].name == "_id",
            identity.components[0].value != .missing,
            identity.components[0].value != .null,
            identity.concurrencyTokens.isEmpty
        else {
            throw DatabaseDocumentMutationRequestError.invalidIdentity
        }
        return identity.components[0].value
    }

    private static func validateDocument(
        _ document: DatabaseValue,
        allowsIdentifier: Bool
    ) throws {
        guard case let .object(fields) = document else {
            throw DatabaseDocumentMutationRequestError.invalidDocument
        }
        try validateFields(fields, allowsIdentifier: allowsIdentifier)
        guard !fields.isEmpty else {
            throw DatabaseDocumentMutationRequestError.missingValues
        }
    }

    private static func validateFields(
        _ fields: [DatabaseObjectField],
        allowsIdentifier: Bool
    ) throws {
        guard fields.count <= 256 else {
            throw DatabaseDocumentMutationRequestError.invalidDocument
        }
        let names = fields.map(\.name)
        guard Set(names).count == names.count else {
            throw DatabaseDocumentMutationRequestError.duplicateField
        }
        guard allowsIdentifier || !names.contains("_id") else {
            throw DatabaseDocumentMutationRequestError.invalidIdentity
        }
        guard names.allSatisfy(validFieldName) else {
            throw DatabaseDocumentMutationRequestError.invalidDocument
        }
    }

    private static func validateSearchDocument(_ document: DatabaseValue) throws {
        guard case let .object(fields) = document,
            fields.count <= 4_096,
            Set(fields.map(\.name)).count == fields.count,
            fields.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1_024 }),
            !fields.contains(where: {
                ["_id", "_index", "_seq_no", "_primary_term", "_highlight"].contains($0.name)
            })
        else {
            throw DatabaseDocumentMutationRequestError.invalidDocument
        }
    }

    private static func searchIdentity(
        _ target: DatabaseTargetIdentifier,
        requiresConcurrency: Bool
    ) throws -> DatabaseSearchDocumentIdentity {
        guard let object = target.object,
            object.kind == .index,
            object.path.count == 1,
            object.nativeIdentifier == nil,
            let identity = target.record,
            identity.kind == .searchDocument,
            identity.components.count == 2,
            case .string(let identityIndex) = identity.components[0].value,
            identity.components[0].name == "_index",
            identityIndex == object.path[0],
            case .string(let identifier) = identity.components[1].value,
            identity.components[1].name == "_id",
            !identifier.isEmpty,
            identifier.utf8.count <= 512
        else {
            throw DatabaseDocumentMutationRequestError.invalidIdentity
        }
        let concurrencyNames = identity.concurrencyTokens.map(\.name)
        guard Set(concurrencyNames).count == concurrencyNames.count else {
            throw DatabaseDocumentMutationRequestError.invalidIdentity
        }
        let concurrency = Dictionary(
            uniqueKeysWithValues: identity.concurrencyTokens.map { ($0.name, $0.value) })
        let sequenceNumber = concurrency["_seq_no"].flatMap(signedInteger)
        let primaryTerm = concurrency["_primary_term"].flatMap(signedInteger)
        guard !requiresConcurrency || sequenceNumber != nil && primaryTerm != nil,
            requiresConcurrency || identity.concurrencyTokens.isEmpty,
            identity.concurrencyTokens.count == (requiresConcurrency ? 2 : 0)
        else {
            throw DatabaseDocumentMutationRequestError.invalidIdentity
        }
        return DatabaseSearchDocumentIdentity(
            index: identityIndex,
            identifier: identifier,
            sequenceNumber: sequenceNumber,
            primaryTerm: primaryTerm)
    }

    private static func signedInteger(_ value: DatabaseValue) -> Int64? {
        guard case .signedInteger(let integer) = value, integer >= 0 else { return nil }
        return integer
    }

    private static func validNamespace(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.contains("\0")
            && !value.contains("/")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validFieldName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 1_024
            && !value.contains("\0")
            && !value.contains(".")
            && !value.hasPrefix("$")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct DatabaseSearchDocumentIdentity: Equatable, Sendable {
    let index: String
    let identifier: String
    let sequenceNumber: Int64?
    let primaryTerm: Int64?
}
