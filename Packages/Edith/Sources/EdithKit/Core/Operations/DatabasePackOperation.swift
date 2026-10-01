import EdithCore

public enum DatabasePackOperation: String, CaseIterable, Sendable {
    case install
    case status
    case remove

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "database.pack.\(rawValue)"),
            summary: summary,
            cli: ["database", "pack", rawValue],
            effect: self == .status ? .read : .write)
    }

    private var summary: String {
        switch self {
        case .install: "Download and verify database drivers."
        case .status: "Inspect the installed database driver pack."
        case .remove: "Remove the installed database driver pack."
        }
    }
}
