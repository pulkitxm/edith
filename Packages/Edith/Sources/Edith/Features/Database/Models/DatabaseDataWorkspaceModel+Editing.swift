import EdithDatabase
import Foundation

extension DatabaseDataWorkspaceModel {
    func beginInsert(_ connection: DatabaseConnectionSummary) {
        guard supportsDataMutation(.insert, connection: connection),
            Self.usesDocumentEditor(connection) || !fields.isEmpty
        else {
            editorError = mutationUnavailableMessage(connection, capability: .insert)
            return
        }
        activeConnection = connection
        activeConnectionID = connection.id
        activeProduct = connection.product
        editorMode = .insert
        editorError = nil
        if connection.product == .mongoDB {
            editorFields = []
            documentText = "{\n  \n}"
        } else if connection.product == .elasticsearch || connection.product == .openSearch {
            editorFields = []
            documentText = "{\n  \"_id\": \"\"\n}"
        } else if connection.product == .redis || connection.product == .valkey {
            editorFields = [
                DatabaseRowFieldDraft(
                    id: "key", typeName: "string", originalValue: nil, isIdentity: true,
                    isEditable: true, text: "", isIncluded: false),
                DatabaseRowFieldDraft(
                    id: "value", typeName: "string", originalValue: nil, isIdentity: false,
                    isEditable: true, text: "", isIncluded: false),
                DatabaseRowFieldDraft(
                    id: "ttlMilliseconds", typeName: "int64", originalValue: nil, isIdentity: false,
                    isEditable: true, text: "", isIncluded: false),
            ]
        } else {
            editorFields = fields.map { field in
                let name = field.path.segments.joined(separator: ".")
                return DatabaseRowFieldDraft(
                    id: name, typeName: field.typeName, originalValue: nil, isIdentity: false,
                    isEditable: field.isGenerated != true
                        && (field.enumValues != nil
                            || Self.supportsEditing(typeName: field.typeName)
                            || isJSONField(field, connection: connection)),
                    text: "",
                    isIncluded: !field.isNullable && field.hasDefault == false
                        && field.isGenerated != true,
                    enumValues: field.enumValues, isNullable: field.isNullable,
                    isGenerated: field.isGenerated == true,
                    hasDefault: field.hasDefault == true,
                    isJSON: isJSONField(field, connection: connection))
            }
        }
    }

    func beginEditingSelectedRow(_ connection: DatabaseConnectionSummary) {
        guard canMutateSelectedRecord(.update, connection: connection), let selectedRecordIndex,
            records.indices.contains(selectedRecordIndex),
            let identity = records[selectedRecordIndex].identity
        else {
            editorError = mutationUnavailableMessage(connection, capability: .update)
            return
        }
        activeConnection = connection
        activeConnectionID = connection.id
        activeProduct = connection.product
        let record = records[selectedRecordIndex]
        let identityNames = Set(identity.components.map(\.name))
        editorMode = .update(recordIndex: selectedRecordIndex)
        editorError = nil
        if Self.usesDocumentEditor(connection) {
            editorFields = []
            do {
                if connection.product == .elasticsearch || connection.product == .openSearch {
                    guard let source = searchEditorSource(record) else {
                        throw DatabaseJSONDocumentCodecError.unsupportedValue
                    }
                    documentText = source
                } else {
                    documentText = try DatabaseJSONDocumentCodec.encodeObject(
                        record.fields.filter { $0.name != "_id" })
                }
            } catch {
                documentText = ""
                editorError = "This document contains values that cannot be edited as JSON."
            }
            return
        }
        let redisString = Self.isRedisString(record)
        editorFields = record.fields.map { field in
            let descriptor = fields.first { $0.path.segments.joined(separator: ".") == field.name }
            let typeName = descriptor?.typeName ?? "text"
            let isIdentity = identityNames.contains(field.name)
            let isEditable: Bool
            if connection.product == .redis || connection.product == .valkey {
                isEditable =
                    field.name == "ttlMilliseconds"
                    || (field.name == "value" && redisString && Self.supportsEditing(field.value))
            } else {
                isEditable =
                    !isIdentity && descriptor?.isGenerated != true
                    && (descriptor?.enumValues != nil || Self.supportsEditing(field.value)
                        || descriptor.map { isJSONField($0, connection: connection) } == true)
            }
            return DatabaseRowFieldDraft(
                id: field.name, typeName: typeName, originalValue: field.value,
                isIdentity: isIdentity,
                isEditable: isEditable, text: Self.text(for: field.value), isIncluded: false,
                enumValues: descriptor?.enumValues, isNullable: descriptor?.isNullable ?? true,
                isNull: field.value == .null, isGenerated: descriptor?.isGenerated == true,
                hasDefault: descriptor?.hasDefault == true,
                isJSON: descriptor.map { isJSONField($0, connection: connection) } == true)
        }
    }

    func canMutateSelectedRecord(
        _ capability: DatabaseCapabilityID, connection: DatabaseConnectionSummary
    ) -> Bool {
        guard let selectedRecordIndex else { return false }
        return canMutateRecord(
            at: selectedRecordIndex, capability: capability, connection: connection)
    }

    func canEdit(recordAt index: Int, field name: String, connection: DatabaseConnectionSummary)
        -> Bool
    {
        guard canMutateRecord(at: index, capability: .update, connection: connection),
            let identity = records[index].identity,
            !identity.components.contains(where: { $0.name == name }),
            let field = fields.first(where: { $0.path.segments.joined(separator: ".") == name })
        else { return false }
        if Self.usesDocumentEditor(connection) { return false }
        if connection.product == .redis || connection.product == .valkey {
            if name == "ttlMilliseconds" { return true }
            return name == "value" && Self.isRedisString(records[index])
                && Self.supportsEditing(value(named: name, in: records[index]))
        }
        return field.isGenerated != true
            && (Self.supportsEditing(typeName: field.typeName)
                || isJSONField(field, connection: connection))
    }

    func usesStructuredEditor(field name: String, connection: DatabaseConnectionSummary) -> Bool {
        guard let field = fields.first(where: { $0.path.segments.joined(separator: ".") == name })
        else { return false }
        return field.enumValues != nil || ["bool", "boolean"].contains(field.typeName.lowercased())
            || isJSONField(field, connection: connection)
    }

    private func isJSONField(
        _ field: DatabaseFieldDescriptor, connection: DatabaseConnectionSummary
    ) -> Bool {
        connection.product == .postgresql
            && ["json", "jsonb"].contains(field.typeName.lowercased())
    }

    func inlineMutationRequest(
        recordAt index: Int, field name: String, text: String, connection: DatabaseConnectionSummary
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
        editorFields[index].isNull = false
        if let originalValue = editorFields[index].originalValue {
            editorFields[index].isIncluded =
                originalValue == .null || text != Self.text(for: originalValue)
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
        guard let index = editorFields.firstIndex(where: { $0.id == id }),
            editorFields[index].isEditable, editorFields[index].isNullable
        else { return }
        editorFields[index].text = "NULL"
        editorFields[index].isNull = true
        editorFields[index].isIncluded = editorFields[index].originalValue != .null
        editorError = nil
    }

    func resetEditorField(_ id: String) {
        guard let index = editorFields.firstIndex(where: { $0.id == id }),
            editorFields[index].isEditable
        else { return }
        editorFields[index].text = editorFields[index].originalValue.map(Self.text(for:)) ?? ""
        editorFields[index].isIncluded = false
        editorFields[index].isNull = editorFields[index].originalValue == .null
        editorError = nil
    }

    func cancelEditor() {
        editorMode = nil
        editorFields = []
        documentText = ""
        editorError = nil
    }
}
