import Foundation

public enum DatabaseDocumentMutationRequestError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidIdentity
    case invalidDocument
    case duplicateField
    case missingValues
}

public enum DatabaseDocumentMutationRequests {
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
