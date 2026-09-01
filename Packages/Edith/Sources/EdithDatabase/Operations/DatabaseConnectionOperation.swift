import EdithCore

public enum DatabaseConnectionOperation: String, CaseIterable, Sendable {
    case add

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "database.connection.add"),
            summary: "Test and save a database connection.",
            cli: ["database", "connections", rawValue],
            effect: .write)
    }
}
