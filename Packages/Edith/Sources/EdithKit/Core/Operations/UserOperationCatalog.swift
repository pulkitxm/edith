import EdithCore

public enum UserOperationCatalog {
    public static let descriptors =
        MachineControlOperation.allCases.map(\.descriptor)
        + ExtensionMutationOperation.allCases.map(\.descriptor)
        + CalendarEventOperation.allCases.map(\.descriptor)
        + ShelfItemOperation.allCases.map(\.descriptor)
        + DownloadOperation.allCases.map(\.descriptor)
        + MusicLibraryOperation.allCases.map(\.descriptor)
        + MusicTransportOperation.allCases.map(\.descriptor)
        + MusicCurrentOperation.allCases.map(\.descriptor)
        + PresenterRuntimeOperation.allCases.map(\.descriptor)
        + ConfigurationOperation.allCases.map(\.descriptor)
        + PermissionOperation.allCases.map(\.descriptor)
        + ColorPickerOperation.allCases.map(\.descriptor)
        + ColorSwatchOperation.allCases.map(\.descriptor)
        + QuinjetOperation.allCases.map(\.descriptor)
        + QuinjetSessionOperation.allCases.map(\.descriptor)

    public static func descriptor(id: UserOperationID) -> UserOperationDescriptor? {
        descriptors.first { $0.id == id }
    }

    public static func descriptor(cli: [String]) -> UserOperationDescriptor? {
        descriptors.first { $0.cli == cli }
    }
}
