import EdithCore

public enum StudioLibraryOperation: String, CaseIterable, Sendable {
    case list, add, remove, clear

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "studio.library.\(rawValue)"), summary: summary,
            cli: ["studio", "library", rawValue], effect: self == .list ? .read : .write)
    }

    public var interfaceExposure: UserOperationExposure {
        .userInterface([
            UserInterfaceActionPlacement(
                surface: "Studio Files", action: summary,
                exampleArguments: self == .add || self == .remove ? ["synthetic.png"] : [])
        ])
    }

    private var summary: String {
        switch self {
        case .list: "List saved media references, including missing files."
        case .add: "Add original files or folders to the media list."
        case .remove: "Remove selected references while preserving source files."
        case .clear: "Clear media references while preserving saved projects."
        }
    }
}
