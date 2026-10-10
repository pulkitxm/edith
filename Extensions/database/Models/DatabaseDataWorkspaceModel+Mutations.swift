import DatabaseCore
import Foundation

extension DatabaseDataWorkspaceModel {
    var canSubmitEditor: Bool {
        guard let editorMode else { return false }
        if let activeConnection, Self.usesDocumentEditor(activeConnection) {
            guard let objectTarget = try? target(activeConnection) else { return false }
            return
                (try? documentEditorMutationRequest(
                    product: activeConnection.product, mode: editorMode, objectTarget: objectTarget))
                != nil
        }
        if editorMode == .insert, activeProduct == .redis || activeProduct == .valkey {
            return editorFields.contains { $0.id == "key" && $0.isIncluded }
                && editorFields.contains { $0.id == "value" && $0.isIncluded }
        }
        if editorMode == .insert, activeProduct == .postgresql { return !editorFields.isEmpty }
        return editorFields.contains { $0.isEditable && $0.isIncluded }
    }

    func editorMutationRequest(_ connection: DatabaseConnectionSummary)
        -> DatabaseDestructiveRequest?
    {
        do {
            guard let editorMode else { throw DatabaseRowEditorError.notEditing }
            let capability: DatabaseCapabilityID = editorMode == .insert ? .insert : .update
            guard supportsDataMutation(capability, connection: connection) else {
                editorError = mutationUnavailableMessage(connection, capability: capability)
                return nil
            }
            let objectTarget = try target(connection)
            let request: DatabaseDestructiveRequest
            if Self.usesDocumentEditor(connection) {
                request = try documentEditorMutationRequest(
                    product: connection.product, mode: editorMode, objectTarget: objectTarget)
            } else {
                let values = try editorFields.filter(\.isIncluded).map {
                    DatabaseObjectField(name: $0.id, value: try Self.value(from: $0))
                }
                let target = try mutationTarget(mode: editorMode, objectTarget: objectTarget)
                request = try rowMutationRequest(
                    product: connection.product, mode: editorMode, target: target, values: values)
            }
            editorError = nil
            return request
        } catch {
            editorError = Self.editorMessage(error)
            return nil
        }
    }

    private func mutationTarget(mode: DatabaseRowEditorMode, objectTarget: DatabaseTargetIdentifier)
        throws -> DatabaseTargetIdentifier
    {
        guard case .update(let index) = mode else { return objectTarget }
        guard records.indices.contains(index), let identity = records[index].identity else {
            throw DatabaseRowEditorError.missingIdentity
        }
        return DatabaseTargetIdentifier(
            connectionID: objectTarget.connectionID, object: objectTarget.object, record: identity)
    }

    private func rowMutationRequest(
        product: DatabaseProduct, mode: DatabaseRowEditorMode, target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        switch (product, mode) {
        case (.postgresql, .insert):
            return try DatabaseRowMutationRequests.postgreSQLInsert(target: target, values: values)
        case (.postgresql, .update):
            return try DatabaseRowMutationRequests.postgreSQLUpdate(target: target, values: values)
        case (.mysql, .insert), (.mariaDB, .insert):
            return try DatabaseRowMutationRequests.mySQLInsert(
                target: target, product: product, values: values)
        case (.mysql, .update), (.mariaDB, .update):
            return try DatabaseRowMutationRequests.mySQLUpdate(
                target: target, product: product, values: values)
        case (.sqlite, .insert):
            return try DatabaseRowMutationRequests.sqliteInsert(target: target, values: values)
        case (.sqlite, .update):
            return try DatabaseRowMutationRequests.sqliteUpdate(target: target, values: values)
        case (.clickHouse, .insert):
            return try DatabaseRowMutationRequests.clickHouseInsert(target: target, values: values)
        case (.redis, .insert), (.valkey, .insert):
            guard let key = values.first(where: { $0.name == "key" })?.value,
                let value = values.first(where: { $0.name == "value" })?.value
            else { throw DatabaseKeyspaceMutationRequestError.invalidValue }
            return try DatabaseKeyspaceMutationRequests.insertString(
                target: target, product: product, key: key, value: value,
                ttlMilliseconds: try Self.redisTTL(values))
        case (.redis, .update), (.valkey, .update):
            let ttlField = values.first { $0.name == "ttlMilliseconds" }
            if let value = values.first(where: { $0.name == "value" })?.value {
                return try DatabaseKeyspaceMutationRequests.updateString(
                    target: target, product: product, value: value,
                    ttlMilliseconds: try Self.redisTTL(values),
                    preservesExistingTTL: ttlField == nil)
            }
            guard ttlField != nil else { throw DatabaseRowMutationRequestError.missingValues }
            return try DatabaseKeyspaceMutationRequests.updateTTL(
                target: target, product: product, ttlMilliseconds: try Self.redisTTL(values))
        default: throw DatabaseRowEditorError.unsupportedDatabase
        }
    }

    private func documentEditorMutationRequest(
        product: DatabaseProduct, mode: DatabaseRowEditorMode,
        objectTarget: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        switch (product, mode) {
        case (.mongoDB, .insert):
            return try DatabaseDocumentMutationRequests.mongoDBInsert(
                target: objectTarget,
                document: .object(try DatabaseJSONDocumentCodec.decodeObject(documentText)))
        case (.mongoDB, .update):
            return try DatabaseDocumentMutationRequests.mongoDBUpdate(
                target: mutationTarget(mode: mode, objectTarget: objectTarget),
                values: DatabaseJSONDocumentCodec.decodeObject(documentText))
        case (.elasticsearch, .insert), (.openSearch, .insert):
            let input = try Self.searchDocumentInput(documentText)
            guard let object = objectTarget.object, let index = object.path.first else {
                throw DatabaseRowEditorError.missingIdentity
            }
            let target = DatabaseTargetIdentifier(
                connectionID: objectTarget.connectionID, object: object,
                record: DatabaseRecordIdentity(
                    kind: .searchDocument,
                    components: [
                        DatabaseIdentityComponent(name: "_index", value: .string(index)),
                        DatabaseIdentityComponent(name: "_id", value: .string(input.identifier)),
                    ]))
            if product == .elasticsearch {
                return try DatabaseDocumentMutationRequests.elasticsearchCreate(
                    target: target, document: .object(input.fields))
            }
            return try DatabaseDocumentMutationRequests.openSearchCreate(
                target: target, document: .object(input.fields))
        case (.elasticsearch, .update), (.openSearch, .update):
            let target = try mutationTarget(mode: mode, objectTarget: objectTarget)
            let input = try Self.searchDocumentInput(documentText)
            guard
                target.record?.components.contains(where: {
                    $0.name == "_id" && $0.value == .string(input.identifier)
                }) == true
            else {
                throw DatabaseRowEditorError.changedIdentity
            }
            if product == .elasticsearch {
                return try DatabaseDocumentMutationRequests.elasticsearchReplace(
                    target: target, document: .object(input.fields))
            }
            return try DatabaseDocumentMutationRequests.openSearchReplace(
                target: target, document: .object(input.fields))
        default: throw DatabaseRowEditorError.unsupportedDatabase
        }
    }

    func deleteMutationRequest(_ connection: DatabaseConnectionSummary)
        -> DatabaseDestructiveRequest?
    {
        do {
            guard canMutateSelectedRecord(.delete, connection: connection),
                let identity = selectedRecord?.identity
            else {
                editorError = mutationUnavailableMessage(connection, capability: .delete)
                return nil
            }
            let objectTarget = try target(connection)
            let target = DatabaseTargetIdentifier(
                connectionID: objectTarget.connectionID, object: objectTarget.object,
                record: identity)
            let request = try Self.executableDeleteMutationRequest(
                product: connection.product, target: target)
            editorError = nil
            return request
        } catch {
            editorError = Self.editorMessage(error)
            return nil
        }
    }

    func canMutateRecord(
        at index: Int, capability: DatabaseCapabilityID, connection: DatabaseConnectionSummary
    ) -> Bool {
        guard capability == .update || capability == .delete,
            supportsDataMutation(capability, connection: connection),
            records.indices.contains(index),
            let identity = records[index].identity, let objectTarget = try? target(connection)
        else { return false }
        if connection.product == .mongoDB, !Self.mongoDBIdentityRoundTrips(identity) {
            return false
        }
        if capability == .update {
            let record = records[index]
            if connection.product == .mongoDB,
                (try? DatabaseJSONDocumentCodec.encodeObject(
                    record.fields.filter { $0.name != "_id" })) == nil
            {
                return false
            }
            if connection.product == .elasticsearch || connection.product == .openSearch,
                searchEditorSource(record) == nil
            {
                return false
            }
        }
        let target = DatabaseTargetIdentifier(
            connectionID: objectTarget.connectionID, object: objectTarget.object, record: identity)
        guard
            let request = try? Self.executableDeleteMutationRequest(
                product: connection.product, target: target)
        else { return false }
        return request.target.record == identity
    }

    private static func executableDeleteMutationRequest(
        product: DatabaseProduct, target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        switch product {
        case .postgresql: try DatabaseRowMutationRequests.postgreSQLDelete(target: target)
        case .mysql, .mariaDB:
            try DatabaseRowMutationRequests.mySQLDelete(target: target, product: product)
        case .sqlite: try DatabaseRowMutationRequests.sqliteDelete(target: target)
        case .redis, .valkey:
            try DatabaseKeyspaceMutationRequests.deleteKey(target: target, product: product)
        case .mongoDB: try DatabaseDocumentMutationRequests.mongoDBDelete(target: target)
        case .elasticsearch:
            try DatabaseDocumentMutationRequests.elasticsearchDelete(target: target)
        case .openSearch: try DatabaseDocumentMutationRequests.openSearchDelete(target: target)
        case .clickHouse: throw DatabaseRowEditorError.unsupportedDatabase
        }
    }

    private static func mongoDBIdentityRoundTrips(_ identity: DatabaseRecordIdentity) -> Bool {
        guard identity.kind == .documentID, identity.components.count == 1,
            identity.components[0].name == "_id", identity.concurrencyTokens.isEmpty
        else { return false }
        let field = DatabaseObjectField(name: "_id", value: identity.components[0].value)
        guard let encoded = try? DatabaseJSONDocumentCodec.encodeObject([field]),
            let decoded = try? DatabaseJSONDocumentCodec.decodeObject(encoded), decoded == [field]
        else { return false }
        if case let .productSpecific(value) = field.value {
            guard value.product == nil || value.product == .mongoDB, value.typeName == "objectId",
                value.binaryRepresentation == nil, value.attributes.isEmpty,
                let text = value.textRepresentation
            else { return false }
            return isMongoDBObjectID(text)
        }
        return true
    }

    func supportsDataMutation(
        _ capability: DatabaseCapabilityID, connection: DatabaseConnectionSummary
    ) -> Bool {
        guard connection.readOnlyPolicy == .disabled, connection.environmentProtection != .readOnly,
            connection.productionPolicy != .prohibitMutations
        else { return false }
        return switch capability {
        case .insert: true
        case .update, .delete: connection.product != .clickHouse
        default: false
        }
    }

    func mutationUnavailableMessage(
        _ connection: DatabaseConnectionSummary, capability: DatabaseCapabilityID
    ) -> String {
        if connection.product == .clickHouse, capability == .update || capability == .delete {
            return "ClickHouse rows cannot be targeted uniquely for safe editing or deletion."
        }
        if connection.readOnlyPolicy != .disabled || connection.environmentProtection == .readOnly
            || connection.productionPolicy == .prohibitMutations
        {
            return "This connection policy does not allow data editing."
        }
        if capability != .insert, !canMutateSelectedRecord(capability, connection: connection) {
            return "This record has no stable identity for safe editing."
        }
        return "Open a table or keyspace before editing data."
    }

    static func usesDocumentEditor(_ connection: DatabaseConnectionSummary) -> Bool {
        connection.product == .mongoDB || connection.product == .elasticsearch
            || connection.product == .openSearch
    }

    private static func searchDocumentInput(_ text: String) throws -> (
        identifier: String, fields: [DatabaseObjectField]
    ) {
        let fields = try DatabaseJSONDocumentCodec.decodePlainObject(text)
        guard let identifierField = fields.first(where: { $0.name == "_id" }),
            case .string(let identifier) = identifierField.value,
            !identifier.isEmpty, identifier.utf8.count <= 512
        else { throw DatabaseRowEditorError.missingIdentity }
        return (identifier, fields.filter { $0.name != "_id" })
    }

    func searchEditorSource(_ record: DatabaseRecord) -> String? {
        guard let identity = record.identity, identity.kind == .searchDocument,
            let identifier = identity.components.first(where: { $0.name == "_id" })
        else { return nil }
        var fields = record.fields.filter { $0.name != "_highlight" && $0.name != "_id" }
        fields.insert(DatabaseObjectField(name: identifier.name, value: identifier.value), at: 0)
        return try? DatabaseJSONDocumentCodec.encodeObject(fields)
    }

    static func isRedisString(_ record: DatabaseRecord) -> Bool {
        record.fields.first(where: { $0.name == "type" })?.value == .string("string")
    }

    private static func redisTTL(_ fields: [DatabaseObjectField]) throws -> Int64? {
        guard let field = fields.first(where: { $0.name == "ttlMilliseconds" }) else { return nil }
        guard case let .signedInteger(value) = field.value, value == -1 || value > 0 else {
            throw DatabaseKeyspaceMutationRequestError.invalidTTL
        }
        return value == -1 ? nil : value
    }

    private static func editorMessage(_ error: Error) -> String {
        if let error = error as? DatabaseRowEditorError {
            switch error {
            case .notEditing: return "Open the row editor before saving."
            case .unsupportedDatabase: return "Data editing is not available for this database yet."
            case .missingIdentity:
                return "This row has no stable primary or unique key for safe editing."
            case .changedIdentity: return "The document identifier cannot be changed while editing."
            case .invalidValue(let field, let type):
                return "Enter a valid \(type) value for \(field)."
            case .unsupportedValue(let field):
                return "The value in \(field) cannot be edited in this form yet."
            }
        }
        if let error = error as? DatabaseRowMutationRequestError {
            switch error {
            case .missingValues: return "Select at least one field to save."
            case .unsupportedIdentity:
                return "This row has no supported stable identity for safe editing."
            case .invalidTarget, .invalidIdentifier, .duplicateField:
                return "The row mutation could not be created safely."
            }
        }
        if let error = error as? DatabaseKeyspaceMutationRequestError {
            switch error {
            case .invalidKey: return "Enter a non-empty key up to 4 KB."
            case .invalidValue: return "Enter a string value up to 64 KB."
            case .invalidTTL: return "Enter -1 for no expiry or a positive TTL in milliseconds."
            case .invalidProduct, .invalidTarget:
                return "The key mutation could not be created safely."
            }
        }
        if let error = error as? DatabaseDocumentMutationRequestError {
            switch error {
            case .missingValues: return "Enter at least one document field."
            case .invalidIdentity: return "This document has no supported stable identifier."
            case .invalidTarget, .invalidDocument, .duplicateField:
                return "The document mutation could not be created safely."
            }
        }
        if let error = error as? DatabaseJSONDocumentCodecError {
            switch error {
            case .invalidJSON: return "Enter a valid JSON document."
            case .invalidDocument: return "The editor requires one JSON object."
            case .unsupportedValue: return "The document contains an unsupported JSON value."
            case .resourceLimit: return "The document exceeds the 1 MB editing limit."
            }
        }
        return "The data mutation could not be created."
    }
}
