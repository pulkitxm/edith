import Foundation

public extension DatabaseRowMutationRequests {
    static func clickHouseInsert(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        guard let object = target.object,
            object.kind == .table,
            object.path.count == 2,
            object.nativeIdentifier == nil,
            target.record == nil
        else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        try object.path.forEach(clickHouseRequestValidateIdentifier)
        guard !values.isEmpty, values.count <= 256 else {
            throw DatabaseRowMutationRequestError.missingValues
        }
        let names = values.map(\.name)
        guard Set(names).count == names.count else {
            throw DatabaseRowMutationRequestError.duplicateField
        }
        try names.forEach(clickHouseRequestValidateIdentifier)
        let table = object.path.map(clickHouseRequestQuote).joined(separator: ".")
        let columns = names.map(clickHouseRequestQuote).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .clickHouse,
                statement: "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))",
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }
}

private func clickHouseRequestValidateIdentifier(_ value: String) throws {
    guard !value.isEmpty,
        value.utf8.count <= 1_024,
        !value.contains("\0"),
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw DatabaseRowMutationRequestError.invalidIdentifier
    }
}

private func clickHouseRequestQuote(_ value: String) -> String {
    "`\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`"
}
