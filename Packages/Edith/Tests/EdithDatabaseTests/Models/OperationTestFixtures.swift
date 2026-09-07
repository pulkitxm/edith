import EdithDatabase
import Foundation

enum DatabaseOperationFixtures {
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "6F196AD2-D226-4F91-8AF2-89BA78351091")!)

    static let object = DatabaseObjectIdentifier(
        kind: .table,
        path: ["orders", "public", "invoices"],
        nativeIdentifier: "16421")

    static let target = DatabaseTargetIdentifier(
        connectionID: DatabaseConnectionFixtures.connectionID,
        object: object,
        record: DatabaseRecordIdentity(
            kind: .primaryKey,
            components: [
                DatabaseIdentityComponent(name: "id", value: .signedInteger(42))
            ],
            concurrencyTokens: [
                DatabaseIdentityComponent(name: "version", value: .signedInteger(7))
            ]))
}
