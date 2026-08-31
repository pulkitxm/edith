import AppKit
import EdithDatabase
import Foundation
import Observation

enum DatabaseDataWorkspaceState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum DatabaseRowEditorMode: Equatable, Sendable {
    case insert
    case update(recordIndex: Int)
}

struct DatabaseRowFieldDraft: Identifiable, Equatable, Sendable {
    let id: String
    let typeName: String
    let originalValue: DatabaseValue?
    let isIdentity: Bool
    let isEditable: Bool
    var text: String
    var isIncluded: Bool
}

@MainActor
@Observable
final class DatabaseDataWorkspaceModel {
    var targetText = ""
    var filterField = ""
    var filterValue = ""
    var sortField = ""
    var sortDirection = DatabaseSortDirection.ascending
    private(set) var state = DatabaseDataWorkspaceState.idle
    private(set) var records: [DatabaseRecord] = []
    private(set) var fields: [DatabaseFieldDescriptor] = []
    private(set) var selectedRecordIndex: Int?
    private(set) var nextContinuation: DatabaseContinuationToken?
    private(set) var metadata: DatabasePageMetadata?
    private(set) var editorMode: DatabaseRowEditorMode?
    private(set) var editorFields: [DatabaseRowFieldDraft] = []
    private(set) var documentText = ""
    private(set) var editorError: String?
    private(set) var selectedObject: DatabaseObjectIdentifier?

    private let sender: any DatabaseBrokerCommandSending
    private let announcement: @MainActor (String) -> Void
    private var activeTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeConnectionID: DatabaseConnectionID?
    private var activeProduct: DatabaseProduct?

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        announcement: @escaping @MainActor (String) -> Void = DatabaseDataWorkspaceModel.announce
    ) {
        self.sender = sender
        self.announcement = announcement
    }

    var selectedRecord: DatabaseRecord? {
        guard let selectedRecordIndex, records.indices.contains(selectedRecordIndex) else {
            return nil
        }
        return records[selectedRecordIndex]
    }

    var hasNextPage: Bool {
        nextContinuation != nil
    }

    var isLoading: Bool {
        state == .loading
    }

    var canSubmitEditor: Bool {
        guard let editorMode else { return false }
        if activeProduct == .mongoDB {
            return !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if editorMode == .insert, activeProduct == .redis || activeProduct == .valkey {
            var includesKey = false
            var includesValue = false
            for field in editorFields where field.isIncluded {
                includesKey = includesKey || field.id == "key"
                includesValue = includesValue || field.id == "value"
            }
            return includesKey && includesValue
        }
        return editorFields.contains(where: { $0.isEditable && $0.isIncluded })
    }

    func prepare(for connection: DatabaseConnectionSummary?) {
        guard activeConnectionID != connection?.id else { return }
        cancel()
        activeConnectionID = connection?.id
        activeProduct = connection?.product
        records = []
        fields = []
        selectedRecordIndex = nil
        nextContinuation = nil
        metadata = nil
        editorMode = nil
        editorFields = []
        documentText = ""
        editorError = nil
        selectedObject = nil
        filterField = ""
        filterValue = ""
        sortField = ""
        sortDirection = .ascending
        state = .idle
        targetText = connection.map(Self.initialTargetText) ?? ""
    }

    func browse(_ connection: DatabaseConnectionSummary, appending: Bool = false) {
        guard !isLoading else { return }
        let continuation = appending ? nextContinuation : nil
        if appending, continuation == nil { return }
        let request: DatabaseBrowseRequest
        do {
            request = try browseRequest(connection, continuation: continuation)
        } catch {
            state = .failed(Self.message(for: error))
            announcement(Self.message(for: error))
            return
        }

        activeTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        state = .loading
        let sender = sender
        activeTask = Task { [weak self] in
            do {
                let response = try await sender.send(.browse(request))
                try Task.checkCancellation()
                self?.finish(
                    response,
                    connectionID: connection.id,
                    generation: requestGeneration,
                    appending: appending)
            } catch is CancellationError {
            } catch {
                self?.fail(error, generation: requestGeneration)
            }
        }
    }

    func refresh(_ connection: DatabaseConnectionSummary) {
        browse(connection)
    }

    func open(
        _ object: DatabaseObjectIdentifier,
        connection: DatabaseConnectionSummary
    ) {
        cancel()
        selectedObject = object
        targetText = object.path.joined(separator: ".")
        browse(connection)
    }

    func loadNextPage(_ connection: DatabaseConnectionSummary) {
        browse(connection, appending: true)
    }

    func selectRecord(at index: Int) {
        guard records.indices.contains(index) else { return }
        cancelEditor()
        selectedRecordIndex = selectedRecordIndex == index ? nil : index
        announcement(selectedRecordIndex == nil ? "Closed row details." : "Opened row details.")
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        generation = UUID()
        if state == .loading {
            state = records.isEmpty ? .idle : .loaded
        }
    }

    func beginInsert(_ connection: DatabaseConnectionSummary) {
        guard supportsDataMutations(connection), connection.product == .mongoDB || !fields.isEmpty
        else {
            editorError = mutationUnavailableMessage(connection)
            return
        }
        editorMode = .insert
        editorError = nil
        if connection.product == .mongoDB {
            editorFields = []
            documentText = "{\n  \n}"
        } else if connection.product == .redis || connection.product == .valkey {
            editorFields = [
                DatabaseRowFieldDraft(
                    id: "key", typeName: "string", originalValue: nil,
                    isIdentity: true, isEditable: true, text: "", isIncluded: false),
                DatabaseRowFieldDraft(
                    id: "value", typeName: "string", originalValue: nil,
                    isIdentity: false, isEditable: true, text: "", isIncluded: false),
                DatabaseRowFieldDraft(
                    id: "ttlMilliseconds", typeName: "int64", originalValue: nil,
                    isIdentity: false, isEditable: true, text: "", isIncluded: false),
            ]
        } else {
            editorFields = fields.map { field in
                let name = field.path.segments.joined(separator: ".")
                return DatabaseRowFieldDraft(
                    id: name,
                    typeName: field.typeName,
                    originalValue: nil,
                    isIdentity: false,
                    isEditable: Self.supportsEditing(typeName: field.typeName),
                    text: "",
                    isIncluded: false)
            }
        }
    }

    func beginEditingSelectedRow(_ connection: DatabaseConnectionSummary) {
        guard supportsDataMutations(connection),
            let selectedRecordIndex,
            records.indices.contains(selectedRecordIndex),
            let identity = records[selectedRecordIndex].identity
        else {
            editorError = mutationUnavailableMessage(connection)
            return
        }
        let record = records[selectedRecordIndex]
        var identityNames = Set<String>()
        for component in identity.components {
            identityNames.insert(component.name)
        }
        editorMode = .update(recordIndex: selectedRecordIndex)
        editorError = nil
        if connection.product == .mongoDB {
            editorFields = []
            do {
                documentText = try DatabaseJSONDocumentCodec.encodeObject(record.fields)
            } catch {
                documentText = ""
                editorError = "This document contains values that cannot be edited as JSON."
            }
            return
        }
        let redisString = Self.isRedisString(record)
        editorFields = record.fields.map { field in
            let typeName =
                fields.first {
                    $0.path.segments.joined(separator: ".") == field.name
                }?.typeName ?? "text"
            let isIdentity = identityNames.contains(field.name)
            let isEditable: Bool
            if connection.product == .redis || connection.product == .valkey {
                isEditable =
                    field.name == "ttlMilliseconds"
                    || (field.name == "value" && redisString && Self.supportsEditing(field.value))
            } else {
                isEditable = !isIdentity && Self.supportsEditing(field.value)
            }
            return DatabaseRowFieldDraft(
                id: field.name,
                typeName: typeName,
                originalValue: field.value,
                isIdentity: isIdentity,
                isEditable: isEditable,
                text: Self.text(for: field.value),
                isIncluded: false)
        }
    }

    func canEdit(
        recordAt index: Int,
        field name: String,
        connection: DatabaseConnectionSummary
    ) -> Bool {
        guard supportsDataMutations(connection), records.indices.contains(index),
            let identity = records[index].identity,
            !identity.components.contains(where: { $0.name == name }),
            let field = fields.first(where: {
                $0.path.segments.joined(separator: ".") == name
            })
        else { return false }
        if connection.product == .mongoDB { return false }
        if connection.product == .redis || connection.product == .valkey {
            if name == "ttlMilliseconds" { return true }
            return name == "value" && Self.isRedisString(records[index])
                && Self.supportsEditing(value(named: name, in: records[index]))
        }
        return Self.supportsEditing(typeName: field.typeName)
    }

    func inlineMutationRequest(
        recordAt index: Int,
        field name: String,
        text: String,
        connection: DatabaseConnectionSummary
    ) -> DatabaseDestructiveRequest? {
        guard canEdit(recordAt: index, field: name, connection: connection) else { return nil }
        selectedRecordIndex = index
        beginEditingSelectedRow(connection)
        updateEditorField(name, text: text)
        return editorMutationRequest(connection)
    }

    func updateEditorField(_ id: String, text: String) {
        guard let index = editorFields.firstIndex(where: { $0.id == id }),
            editorFields[index].isEditable
        else { return }
        editorFields[index].text = text
        if let originalValue = editorFields[index].originalValue {
            editorFields[index].isIncluded = text != Self.text(for: originalValue)
        } else {
            editorFields[index].isIncluded = true
        }
        editorError = nil
    }

    func updateDocumentText(_ text: String) {
        documentText = text
        editorError = nil
    }

    func setEditorFieldIncluded(_ id: String, included: Bool) {
        guard let index = editorFields.firstIndex(where: { $0.id == id }),
            editorFields[index].isEditable
        else { return }
        editorFields[index].isIncluded = included
        editorError = nil
    }

    func setEditorFieldNull(_ id: String) {
        updateEditorField(id, text: "NULL")
    }

    func resetEditorField(_ id: String) {
        guard let index = editorFields.firstIndex(where: { $0.id == id }),
            editorFields[index].isEditable
        else { return }
        editorFields[index].text = editorFields[index].originalValue.map(Self.text(for:)) ?? ""
        editorFields[index].isIncluded = false
        editorError = nil
    }

    func cancelEditor() {
        editorMode = nil
        editorFields = []
        documentText = ""
        editorError = nil
    }

    func editorMutationRequest(
        _ connection: DatabaseConnectionSummary
    ) -> DatabaseDestructiveRequest? {
        do {
            var values: [DatabaseObjectField] = []
            for field in editorFields where field.isIncluded {
                values.append(
                    DatabaseObjectField(
                        name: field.id,
                        value: try Self.value(from: field)))
            }
            let objectTarget = try target(connection)
            switch (connection.product, editorMode) {
            case (.mongoDB, .insert):
                let request = try DatabaseDocumentMutationRequests.mongoDBInsert(
                    target: objectTarget,
                    document: .object(try DatabaseJSONDocumentCodec.decodeObject(documentText)))
                editorError = nil
                return request
            case (.mongoDB, .update(let recordIndex)):
                guard records.indices.contains(recordIndex),
                    let identity = records[recordIndex].identity
                else {
                    throw DatabaseRowEditorError.missingIdentity
                }
                let request = try DatabaseDocumentMutationRequests.mongoDBUpdate(
                    target: DatabaseTargetIdentifier(
                        connectionID: objectTarget.connectionID,
                        object: objectTarget.object,
                        record: identity),
                    values: try DatabaseJSONDocumentCodec.decodeObject(documentText))
                editorError = nil
                return request
            case (.postgresql, .insert):
                let request = try DatabaseRowMutationRequests.postgreSQLInsert(
                    target: objectTarget,
                    values: values)
                editorError = nil
                return request
            case (.postgresql, .update(let recordIndex)):
                guard records.indices.contains(recordIndex),
                    let identity = records[recordIndex].identity
                else {
                    throw DatabaseRowEditorError.missingIdentity
                }
                let request = try DatabaseRowMutationRequests.postgreSQLUpdate(
                    target: DatabaseTargetIdentifier(
                        connectionID: objectTarget.connectionID,
                        object: objectTarget.object,
                        record: identity),
                    values: values)
                editorError = nil
                return request
            case (.redis, .insert), (.valkey, .insert):
                guard let key = values.first(where: { $0.name == "key" })?.value,
                    let value = values.first(where: { $0.name == "value" })?.value
                else {
                    throw DatabaseKeyspaceMutationRequestError.invalidValue
                }
                let request = try DatabaseKeyspaceMutationRequests.insertString(
                    target: objectTarget,
                    product: connection.product,
                    key: key,
                    value: value,
                    ttlMilliseconds: try Self.redisTTL(values))
                editorError = nil
                return request
            case (.redis, .update(let recordIndex)), (.valkey, .update(let recordIndex)):
                guard records.indices.contains(recordIndex),
                    let identity = records[recordIndex].identity
                else {
                    throw DatabaseRowEditorError.missingIdentity
                }
                let target = DatabaseTargetIdentifier(
                    connectionID: objectTarget.connectionID,
                    object: objectTarget.object,
                    record: identity)
                let value = values.first(where: { $0.name == "value" })?.value
                let ttlField = values.first(where: { $0.name == "ttlMilliseconds" })
                if let value {
                    let ttl = try ttlField.map { try Self.redisTTL([$0]) }
                    let request = try DatabaseKeyspaceMutationRequests.updateString(
                        target: target,
                        product: connection.product,
                        value: value,
                        ttlMilliseconds: ttl ?? nil,
                        preservesExistingTTL: ttlField == nil)
                    editorError = nil
                    return request
                }
                guard ttlField != nil else {
                    throw DatabaseRowMutationRequestError.missingValues
                }
                let request = try DatabaseKeyspaceMutationRequests.updateTTL(
                    target: target,
                    product: connection.product,
                    ttlMilliseconds: try Self.redisTTL(values))
                editorError = nil
                return request
            case (_, nil):
                throw DatabaseRowEditorError.notEditing
            default:
                throw DatabaseRowEditorError.unsupportedDatabase
            }
        } catch {
            editorError = Self.editorMessage(error)
            return nil
        }
    }

    func deleteMutationRequest(
        _ connection: DatabaseConnectionSummary
    ) -> DatabaseDestructiveRequest? {
        do {
            guard supportsDataMutations(connection), let record = selectedRecord,
                let identity = record.identity
            else {
                throw DatabaseRowEditorError.missingIdentity
            }
            let objectTarget = try target(connection)
            let target = DatabaseTargetIdentifier(
                connectionID: objectTarget.connectionID,
                object: objectTarget.object,
                record: identity)
            let request: DatabaseDestructiveRequest
            if connection.product == .redis || connection.product == .valkey {
                request = try DatabaseKeyspaceMutationRequests.deleteKey(
                    target: target,
                    product: connection.product)
            } else if connection.product == .mongoDB {
                request = try DatabaseDocumentMutationRequests.mongoDBDelete(target: target)
            } else {
                request = try DatabaseRowMutationRequests.postgreSQLDelete(target: target)
            }
            editorError = nil
            return request
        } catch {
            editorError = Self.editorMessage(error)
            return nil
        }
    }

    func finishMutation(_ connection: DatabaseConnectionSummary) {
        cancelEditor()
        browse(connection)
    }

    func text(for value: DatabaseValue) -> String {
        Self.text(for: value)
    }

    func documentSource(_ record: DatabaseRecord) -> String? {
        var sourceFields = record.fields
        if let identity = record.identity,
            identity.kind == .documentID,
            let identifier = identity.components.first,
            !sourceFields.contains(where: { $0.name == identifier.name })
        {
            sourceFields.insert(
                DatabaseObjectField(name: identifier.name, value: identifier.value), at: 0)
        }
        return try? DatabaseJSONDocumentCodec.encodeObject(sourceFields)
    }

    func value(named name: String, in record: DatabaseRecord) -> DatabaseValue {
        record.fields.first(where: { $0.name == name })?.value ?? .missing
    }

    private func browseRequest(
        _ connection: DatabaseConnectionSummary,
        continuation: DatabaseContinuationToken?
    ) throws -> DatabaseBrowseRequest {
        let pageSize = try DatabasePageSize(100)
        let filter: DatabaseFilter?
        let normalizedFilterField = filterField.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilterValue = filterValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedFilterField.isEmpty || normalizedFilterValue.isEmpty {
            filter = nil
        } else {
            filter = .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath(normalizedFilterField),
                    operation: .contains,
                    values: [.string(normalizedFilterValue)],
                    caseSensitivity: .insensitive))
        }
        let normalizedSort = sortField.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorts =
            normalizedSort.isEmpty
            ? []
            : [
                DatabaseSort(
                    field: DatabaseFieldPath(normalizedSort),
                    direction: sortDirection)
            ]
        return DatabaseBrowseRequest(
            target: try target(connection),
            page: DatabasePageRequest(
                pageSize: pageSize,
                continuation: continuation,
                filter: filter,
                sorts: sorts))
    }

    private func target(
        _ connection: DatabaseConnectionSummary
    ) throws -> DatabaseTargetIdentifier {
        if let selectedObject {
            return DatabaseTargetIdentifier(connectionID: connection.id, object: selectedObject)
        }
        let entered = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = entered.split(separator: ".", omittingEmptySubsequences: true).map(
            String.init)
        let object: DatabaseObjectIdentifier
        switch connection.product {
        case .postgresql:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultSchema ?? "public",
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        case .sqlite:
            guard (1...2).contains(segments.count) else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter a table name, such as customers.")
            }
            object = DatabaseObjectIdentifier(kind: .table, path: segments)
        case .mysql, .mariaDB:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        case .redis, .valkey:
            guard segments.count <= 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one logical database number or leave it empty.")
            }
            let path =
                segments.isEmpty
                ? connection.logicalDatabase.map { [$0] } ?? []
                : segments
            object = DatabaseObjectIdentifier(kind: .keyspace, path: path)
        case .mongoDB:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .collection, path: path)
        case .elasticsearch, .openSearch:
            guard segments.count == 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one index name, such as products.")
            }
            object = DatabaseObjectIdentifier(kind: .index, path: segments)
        case .clickHouse:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        }
        return DatabaseTargetIdentifier(connectionID: connection.id, object: object)
    }

    private func relationalPath(
        _ segments: [String],
        defaultNamespace: String?,
        product: DatabaseProduct
    ) throws -> [String] {
        if segments.count == 2 { return segments }
        if segments.count == 1, let defaultNamespace {
            return [defaultNamespace, segments[0]]
        }
        throw DatabaseDataWorkspaceInputError.invalidTarget(
            "Enter a namespace and object, such as public.customers, for \(product.displayName).")
    }

    private func finish(
        _ response: DatabaseBrokerCommandResponse,
        connectionID: DatabaseConnectionID,
        generation: UUID,
        appending: Bool
    ) {
        guard self.generation == generation, activeConnectionID == connectionID else { return }
        activeTask = nil
        guard case .browse(let result) = response else {
            state = .failed("The database returned an unexpected browse response.")
            return
        }
        guard result.status != .failed, let page = result.payload?.page else {
            state = .failed(Self.message(for: result.error))
            announcement(Self.message(for: result.error))
            return
        }
        if appending {
            records.append(contentsOf: page.records)
        } else {
            records = page.records
            selectedRecordIndex = nil
        }
        fields = page.fields
        nextContinuation = page.nextContinuation
        metadata = page.metadata
        state = .loaded
        announcement("Loaded \(page.records.count) database records.")
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        activeTask = nil
        let message = Self.message(for: error)
        state = .failed(message)
        announcement(message)
    }

    private static func initialTargetText(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.product {
        case .redis, .valkey:
            connection.logicalDatabase ?? ""
        case .postgresql:
            if let defaultSchema = connection.defaultSchema {
                "\(defaultSchema)."
            } else {
                "public."
            }
        case .mysql, .mariaDB, .mongoDB, .clickHouse:
            if let defaultDatabase = connection.defaultDatabase {
                "\(defaultDatabase)."
            } else {
                ""
            }
        case .sqlite, .elasticsearch, .openSearch:
            ""
        }
    }

    private static func text(for value: DatabaseValue) -> String {
        switch value {
        case .missing: "missing"
        case .null: "null"
        case .boolean(let value): value ? "true" : "false"
        case .signedInteger(let value): value.formatted()
        case .unsignedInteger(let value): value.formatted()
        case .decimal(let value): value.rawValue
        case .floatingPoint(let value): value.formatted()
        case .string(let value): value
        case .binary(let value): "\(value.byteCount.formatted()) bytes"
        case .date(let value): value.text
        case .time(let value): value.text
        case .timestamp(let value): value.text
        case .uuid(let value): value.uuidString.lowercased()
        case .array(let values): "[\(values.count) values]"
        case .object(let fields): "{\(fields.count) fields}"
        case .productSpecific(let value): value.textRepresentation ?? value.typeName
        }
    }

    func supportsDataMutations(_ connection: DatabaseConnectionSummary) -> Bool {
        (connection.product == .postgresql || connection.product == .redis
            || connection.product == .valkey || connection.product == .mongoDB)
            && connection.readOnlyPolicy == .disabled
            && connection.environmentProtection != .readOnly
            && connection.productionPolicy != .prohibitMutations
    }

    private func mutationUnavailableMessage(_ connection: DatabaseConnectionSummary) -> String {
        if connection.product != .postgresql && connection.product != .redis
            && connection.product != .valkey && connection.product != .mongoDB
        {
            return "Data editing is not available for this database yet."
        }
        if connection.readOnlyPolicy != .disabled
            || connection.environmentProtection == .readOnly
            || connection.productionPolicy == .prohibitMutations
        {
            return "This connection policy does not allow data editing."
        }
        if selectedRecord?.identity == nil {
            return "This record has no stable identity for safe editing."
        }
        return "Open a table or keyspace before editing data."
    }

    private static func isRedisString(_ record: DatabaseRecord) -> Bool {
        value(named: "type", in: record) == .string("string")
    }

    private static func value(named name: String, in record: DatabaseRecord) -> DatabaseValue {
        record.fields.first(where: { $0.name == name })?.value ?? .missing
    }

    private static func redisTTL(_ fields: [DatabaseObjectField]) throws -> Int64? {
        guard let field = fields.first(where: { $0.name == "ttlMilliseconds" }) else {
            return nil
        }
        guard case let .signedInteger(value) = field.value, value == -1 || value > 0 else {
            throw DatabaseKeyspaceMutationRequestError.invalidTTL
        }
        return value == -1 ? nil : value
    }

    private static func supportsEditing(_ value: DatabaseValue) -> Bool {
        switch value {
        case .missing, .binary, .array, .object, .productSpecific:
            false
        case .null, .boolean, .signedInteger, .unsignedInteger, .decimal, .floatingPoint,
            .string, .date, .time, .timestamp, .uuid:
            true
        }
    }

    private static func supportsEditing(typeName: String) -> Bool {
        let type = typeName.lowercased()
        return !type.contains("bytea")
            && !type.contains("json")
            && !type.hasSuffix("[]")
    }

    private static func value(
        from field: DatabaseRowFieldDraft
    ) throws -> DatabaseValue {
        let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "NULL" {
            return .null
        }
        if let original = field.originalValue {
            switch original {
            case .boolean:
                guard let value = parseBoolean(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .boolean(value)
            case .signedInteger:
                guard let value = Int64(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .signedInteger(value)
            case .unsignedInteger:
                guard let value = UInt64(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .unsignedInteger(value)
            case .decimal:
                return .decimal(DatabaseDecimalValue(rawValue: trimmed))
            case .floatingPoint:
                guard let value = Double(trimmed), value.isFinite else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .floatingPoint(value)
            case .string:
                return .string(field.text)
            case .date:
                return .date(DatabaseDateValue(text: trimmed))
            case .time:
                return .time(DatabaseTimeValue(text: trimmed))
            case .timestamp:
                return .timestamp(DatabaseTimestampValue(text: trimmed))
            case .uuid:
                guard let value = UUID(uuidString: trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .uuid(value)
            case .null:
                break
            case .missing, .binary, .array, .object, .productSpecific:
                throw DatabaseRowEditorError.unsupportedValue(field.id)
            }
        }
        return try value(from: field.text, typeName: field.typeName, fieldName: field.id)
    }

    private static func value(
        from text: String,
        typeName: String,
        fieldName: String
    ) throws -> DatabaseValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = typeName.lowercased()
        if type.contains("bool") {
            guard let value = parseBoolean(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .boolean(value)
        }
        if type.contains("int") || type.contains("serial") {
            guard let value = Int64(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .signedInteger(value)
        }
        if type.contains("numeric") || type.contains("decimal") {
            return .decimal(DatabaseDecimalValue(rawValue: trimmed))
        }
        if type.contains("real") || type.contains("double") {
            guard let value = Double(trimmed), value.isFinite else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .floatingPoint(value)
        }
        if type == "uuid" {
            guard let value = UUID(uuidString: trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .uuid(value)
        }
        if type.contains("timestamp") {
            return .timestamp(DatabaseTimestampValue(text: trimmed))
        }
        if type == "date" {
            return .date(DatabaseDateValue(text: trimmed))
        }
        if type.hasPrefix("time") {
            return .time(DatabaseTimeValue(text: trimmed))
        }
        return .string(text)
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "t", "1", "yes": true
        case "false", "f", "0", "no": false
        default: nil
        }
    }

    private static func editorMessage(_ error: Error) -> String {
        if let editorError = error as? DatabaseRowEditorError {
            switch editorError {
            case .notEditing: return "Open the row editor before saving."
            case .unsupportedDatabase:
                return "Data editing is not available for this database yet."
            case .missingIdentity:
                return "This row has no stable primary or unique key for safe editing."
            case .invalidValue(let field, let type):
                return "Enter a valid \(type) value for \(field)."
            case .unsupportedValue(let field):
                return "The value in \(field) cannot be edited in this form yet."
            }
        }
        if let requestError = error as? DatabaseRowMutationRequestError {
            switch requestError {
            case .missingValues: return "Select at least one field to save."
            case .unsupportedIdentity:
                return "This row has no supported stable identity for safe editing."
            case .invalidTarget, .invalidIdentifier, .duplicateField:
                return "The row mutation could not be created safely."
            }
        }
        if let requestError = error as? DatabaseKeyspaceMutationRequestError {
            switch requestError {
            case .invalidKey: return "Enter a non-empty key up to 4 KB."
            case .invalidValue: return "Enter a string value up to 64 KB."
            case .invalidTTL: return "Enter -1 for no expiry or a positive TTL in milliseconds."
            case .invalidProduct, .invalidTarget:
                return "The key mutation could not be created safely."
            }
        }
        if let requestError = error as? DatabaseDocumentMutationRequestError {
            switch requestError {
            case .missingValues: return "Enter at least one document field."
            case .invalidIdentity: return "This document has no supported stable identifier."
            case .invalidTarget, .invalidDocument, .duplicateField:
                return "The document mutation could not be created safely."
            }
        }
        if let documentError = error as? DatabaseJSONDocumentCodecError {
            switch documentError {
            case .invalidJSON: return "Enter a valid JSON document."
            case .invalidDocument: return "The editor requires one JSON object."
            case .unsupportedValue: return "The document contains an unsupported JSON value."
            case .resourceLimit: return "The document exceeds the 1 MB editing limit."
            }
        }
        return "The data mutation could not be created."
    }

    private static func message(for error: Error) -> String {
        if let inputError = error as? DatabaseDataWorkspaceInputError {
            switch inputError {
            case .invalidTarget(let message): return message
            }
        }
        if let client = error as? DatabaseBrokerCommandClientError {
            switch client {
            case .timedOut: return "The data request timed out."
            case .unavailable: return "The database broker is unavailable."
            case .unsafePeer: return "The database broker could not be verified."
            case .outcomeUnknown: return "The data request outcome could not be confirmed."
            case .invalidRequest: return "The database rejected this data request."
            }
        }
        return "The data could not be loaded."
    }

    private static func message(for error: DatabaseErrorEnvelope?) -> String {
        error?.message ?? "The data could not be loaded."
    }

    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}

private enum DatabaseDataWorkspaceInputError: Error {
    case invalidTarget(String)
}

private enum DatabaseRowEditorError: Error {
    case notEditing
    case unsupportedDatabase
    case missingIdentity
    case invalidValue(String, String)
    case unsupportedValue(String)
}
