import EdithCore

public enum DatabaseConnectionOperation: String, CaseIterable, Sendable {
    case add
    case edit
    case connect
    case disconnect

    public var descriptor: UserOperationDescriptor {
        let path: [String]
        switch self {
        case .add, .edit:
            path = ["database", "connections", rawValue]
        case .connect, .disconnect:
            path = ["database", rawValue]
        }
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "database.connection.\(rawValue)"),
            summary: summary,
            cli: path,
            effect: .write)
    }

    private var summary: String {
        switch self {
        case .add: "Test and save a database connection."
        case .edit: "Edit database connection metadata and safety policies."
        case .connect: "Open a database session."
        case .disconnect: "Close a database session."
        }
    }
}
