import EdithCore

public enum UserOperationCatalog {
    public static let descriptors = MachineControlOperation.allCases.map(\.descriptor)

    public static func descriptor(id: UserOperationID) -> UserOperationDescriptor? {
        descriptors.first { $0.id == id }
    }

    public static func descriptor(cli: [String]) -> UserOperationDescriptor? {
        descriptors.first { $0.cli == cli }
    }
}
